use std::ffi::{CString, OsString};
use std::fs::{self, File, OpenOptions};
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
        "executionId":{"type":"string", "pattern":"^[a-fA-F0-9]{8,32}$", "description":"Full execution ID or a unique hexadecimal prefix of at least 8 characters."},
        "step":{"type":"integer", "minimum":0, "maximum":u32::MAX, "default":0},
        "tail":{"type":"integer", "minimum":1, "maximum":1000, "default":100},
        "contains":{"type":"string", "description":"Case-sensitive literal filter within the captured suffix."}
    }})
}

pub fn resolve_id(store: &ExecutionStore, id: &str) -> Result<String, String> {
    if !(8..=32).contains(&id.len()) || !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("executionId must contain 8 to 32 hexadecimal characters".into());
    }
    let prefix = id.to_ascii_lowercase();
    if prefix.len() == 32 {
        return Ok(prefix);
    }
    resolve_prefix(store, &prefix)
}

fn resolve_prefix(store: &ExecutionStore, prefix: &str) -> Result<String, String> {
    let mut found = None;
    for entry in fs::read_dir(&store.root).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        let name = entry.file_name();
        let Some(candidate) = name.to_str().and_then(|name| name.strip_suffix(".json")) else {
            continue;
        };
        if candidate.starts_with(prefix) && crate::mcp_execution::validate_id(candidate).is_ok() {
            if found.replace(candidate.to_owned()).is_some() {
                return Err(format!(
                    "Ambiguous executionId prefix '{prefix}'; use a longer prefix or the full ID"
                ));
            }
        }
    }
    found.ok_or_else(|| format!("No execution found for executionId prefix '{prefix}'"))
}

pub fn schema() -> Value {
    json!({"type":"object", "required":["step","streams"], "properties":{
        "step":{"type":"integer"},
        "streams":{"type":"array", "items":{"type":"object",
            "required":["stream","lines","readStatus","truncated","truncatedBeforeFilter","truncatedByTail","error"], "properties":{
                "stream":{"enum":["stdout","stderr","supervisor","maven"]},
                "lines":{"type":"array","items":{"type":"string"}},
                "readStatus":{"enum":["ok","empty","no_matches","missing","error"]},
                "truncated":{"type":"boolean","description":"True when either truncation flag is true."},
                "truncatedBeforeFilter":{"type":"boolean","description":"Older content was outside the 16 KiB window searched."},
                "truncatedByTail":{"type":"boolean","description":"More lines matched inside the search window than tail returned."},
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

struct StreamSnapshot {
    lines: Vec<String>,
    status: &'static str,
    clipped: bool,
    limited: bool,
}

fn read_stream(
    directory: &File,
    name: &str,
    tail: usize,
    contains: Option<&str>,
) -> io::Result<StreamSnapshot> {
    let mut file = open_stream(directory, name)?;
    let end = file.metadata()?.len();
    let start = end.saturating_sub(STREAM_BYTES);
    file.seek(SeekFrom::Start(start.saturating_sub(1)))?;
    let mut bytes = Vec::new();
    file.take((end - start) + u64::from(start > 0))
        .read_to_end(&mut bytes)?;
    let bytes = discard_partial_line(&bytes, start > 0);
    Ok(select_lines(bytes, end == 0, start > 0, tail, contains))
}

fn select_lines(
    bytes: &[u8],
    empty_file: bool,
    clipped: bool,
    tail: usize,
    contains: Option<&str>,
) -> StreamSnapshot {
    let output = String::from_utf8_lossy(bytes);
    let mut matched = output
        .lines()
        .rev()
        .filter(|line| contains.is_none_or(|needle| line.contains(needle)));
    let mut lines: Vec<_> = matched.by_ref().take(tail).map(str::to_owned).collect();
    let limited = matched.next().is_some();
    lines.reverse();
    let status = match (empty_file, lines.is_empty()) {
        (true, _) => "empty",
        (_, true) if contains.is_some() => "no_matches",
        (_, true) => "empty",
        _ => "ok",
    };
    StreamSnapshot {
        lines,
        status,
        clipped,
        limited,
    }
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

fn stream_result(stream: &str, result: io::Result<StreamSnapshot>) -> Value {
    let (lines, status, clipped, limited, error) = match result {
        Ok(snapshot) => (
            snapshot.lines,
            snapshot.status,
            snapshot.clipped,
            snapshot.limited,
            None,
        ),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            (vec![], "missing", false, false, None)
        }
        Err(error) => (vec![], "error", false, false, Some(error.to_string())),
    };
    json!({"stream":stream,"lines":lines,"readStatus":status,"truncated":clipped || limited,
        "truncatedBeforeFilter":clipped,"truncatedByTail":limited,"error":error})
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
    print_snapshot(&ExecutionStore::new()?, id, &args)
}

fn print_snapshot(store: &ExecutionStore, id: &str, args: &Value) -> Result<(), String> {
    let record = store.get(&resolve_id(store, id)?)?.snapshot();
    let logs = read(store, &record, args)?;
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
