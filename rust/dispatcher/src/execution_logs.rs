use std::ffi::{CString, OsString};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::OpenOptionsExt;

use serde_json::{json, Value};

use crate::mcp_execution::{ExecutionRecord, ExecutionStore};

const STREAM_BYTES: u64 = 16 * 1024;
const HELP: &str = "Usage: makevn execution-logs ID [--step N] [--tail N] [--contains TEXT]\nRead bounded JSON logs from an execution recorded by MakeVN MCP.";

pub fn input_schema() -> Value {
    json!({"type":"object", "required":["executionId"], "additionalProperties":false,
    "properties":{
        "executionId":{"type":"string", "pattern":"^[a-fA-F0-9]{32}$"},
        "step":{"type":"integer", "minimum":0, "maximum":u32::MAX, "default":0},
        "tail":{"type":"integer", "minimum":1, "maximum":1000, "default":100},
        "contains":{"type":"string", "description":"Case-sensitive literal filter within the captured suffix."}
    }})
}

pub fn schema() -> Value {
    json!({"type":"object", "required":["step","streams"], "properties":{
        "step":{"type":"integer"},
        "streams":{"type":"array", "items":{"type":"object",
            "required":["stream","lines","readStatus","truncated","error"], "properties":{
                "stream":{"enum":["stdout","stderr","supervisor","maven"]},
                "lines":{"type":"array","items":{"type":"string"}},
                "readStatus":{"enum":["ok","empty","no_matches","missing","error"]},
                "truncated":{"type":"boolean"},
                "error":{"type":["string","null"]}
            }
        }}
    }})
}

pub fn read(
    store: &ExecutionStore,
    record: &ExecutionRecord,
    args: &Value,
) -> Result<Value, String> {
    crate::mcp_execution::validate_id(&record.execution_id)?;
    let tail = integer(args, "tail", 100, 1, 1000)? as usize;
    let step = integer(args, "step", 0, 0, u32::MAX.into())?;
    let contains = args["contains"].as_str();
    let streams = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(store.root.join(&record.execution_id))
    {
        Ok(directory) => [
            ("stdout", format!("{step}.stdout.log")),
            ("stderr", format!("{step}.stderr.log")),
            ("supervisor", "supervisor.log".into()),
            ("maven", format!("{step}.maven.log")),
        ]
        .map(|(stream, name)| {
            stream_result(stream, read_stream(&directory, &name, tail, contains))
        }),
        Err(error) => ["stdout", "stderr", "supervisor", "maven"]
            .map(|stream| stream_result(stream, Err(io::Error::from(error.kind())))),
    };
    Ok(json!({"step":step,"streams":streams}))
}

fn integer(args: &Value, name: &str, default: u64, min: u64, max: u64) -> Result<u64, String> {
    match args.get(name) {
        None => Ok(default),
        Some(value) => value
            .as_u64()
            .filter(|value| (min..=max).contains(value))
            .ok_or_else(|| format!("{name} must be an integer between {min} and {max}")),
    }
}

fn open_stream(directory: &File, name: &str) -> io::Result<File> {
    let name = CString::new(name)?;
    // Open relative to the pinned directory and reject symlinks and blocking special files.
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let file = unsafe { File::from_raw_fd(fd) };
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "expected a regular log file",
        ));
    }
    Ok(file)
}

fn read_stream(
    directory: &File,
    name: &str,
    tail: usize,
    contains: Option<&str>,
) -> io::Result<(Vec<String>, &'static str, bool)> {
    let mut file = open_stream(directory, name)?;
    let end = file.metadata()?.len();
    let start = end.saturating_sub(STREAM_BYTES);
    file.seek(SeekFrom::Start(start.saturating_sub(1)))?;
    let mut bytes = Vec::new();
    file.take((end - start) + u64::from(start > 0))
        .read_to_end(&mut bytes)?;
    let bytes = discard_partial_line(&bytes, start > 0);
    let output = String::from_utf8_lossy(bytes);
    let mut matched = output
        .lines()
        .rev()
        .filter(|line| contains.is_none_or(|needle| line.contains(needle)));
    let mut lines: Vec<_> = matched.by_ref().take(tail).map(str::to_owned).collect();
    let truncated = start > 0 || matched.next().is_some();
    lines.reverse();
    let status = match (bytes.is_empty(), lines.is_empty()) {
        (true, _) if end == 0 => "empty",
        (_, true) if contains.is_some() => "no_matches",
        (_, true) => "empty",
        _ => "ok",
    };
    Ok((lines, status, truncated))
}

fn discard_partial_line(bytes: &[u8], clipped: bool) -> &[u8] {
    if clipped {
        bytes
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(&[], |newline| &bytes[newline + 1..])
    } else {
        bytes
    }
}

fn stream_result(stream: &str, result: io::Result<(Vec<String>, &'static str, bool)>) -> Value {
    let (lines, status, truncated, error) = match result {
        Ok((lines, status, truncated)) => (lines, status, truncated, None),
        Err(error) if error.kind() == io::ErrorKind::NotFound => (vec![], "missing", false, None),
        Err(error) => (vec![], "error", false, Some(error.to_string())),
    };
    json!({"stream":stream,"lines":lines,"readStatus":status,"truncated":truncated,"error":error})
}

pub fn cli(args: Vec<OsString>) -> Result<(), String> {
    let Some((id, options)) = args.split_first() else {
        return Err(HELP.into());
    };
    if id == "--help" || id == "-h" {
        println!("{HELP}");
        return Ok(());
    }
    let id = id.to_str().ok_or("execution ID must be UTF-8")?;
    let args = cli_options(options)?;
    let store = ExecutionStore::new()?;
    let record = store.get(id)?.snapshot();
    let logs = read(&store, &record, &args)?;
    println!(
        "{}",
        json!({"execution":record,"untrustedData":{"executionLogs":logs}})
    );
    Ok(())
}

fn cli_options(options: &[OsString]) -> Result<Value, String> {
    let mut args = json!({});
    for pair in options.chunks(2) {
        let [flag, value] = pair else {
            return Err(HELP.into());
        };
        let value = value.to_str().ok_or("option values must be UTF-8")?;
        match flag.to_str() {
            Some("--step") => {
                args["step"] = json!(value.parse::<u64>().map_err(|_| "invalid step")?)
            }
            Some("--tail") => {
                args["tail"] = json!(value.parse::<u64>().map_err(|_| "invalid tail")?)
            }
            Some("--contains") => args["contains"] = json!(value),
            _ => return Err(HELP.into()),
        }
    }
    Ok(args)
}

#[cfg(test)]
#[path = "execution_logs_test.rs"]
mod tests;
