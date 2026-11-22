use std::ffi::{CString, OsString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::mcp_execution::{ExecutionRecord, ExecutionStore};

const STREAM_BYTES: u64 = 16 * 1024;
const HELP: &str = "Usage: makevn execution-logs ID [--step N] [--tail N] [--contains TEXT] [--stream NAME] [--paginate] [--cursor TOKEN]\nRead bounded JSON logs from an execution recorded by MakeVN MCP.";

pub fn input_schema() -> Value {
    json!({"type":"object", "required":["executionId"], "additionalProperties":false,
    "properties":{
        "executionId":{"type":"string", "pattern":"^[a-fA-F0-9]{8,32}$", "description":"Full execution ID or a unique hexadecimal prefix of at least 8 characters."},
        "step":{"type":"integer", "minimum":0, "maximum":u32::MAX, "default":0},
        "tail":{"type":"integer", "minimum":1, "maximum":1000, "default":100},
        "contains":{"type":"string", "description":"Case-sensitive literal filter within the current page."},
        "stream":{"type":"string", "enum":STREAMS, "description":"Read just this stream. Omit to read all streams."},
        "paginate":{"type":"boolean", "default":false, "description":"Opt in to backward pagination. Leave false for a bounded diagnostic snapshot."},
        "cursor":{"type":"string", "maxLength":256, "description":"Pass a stream’s nextCursor to read its preceding page. Keep the same executionId, step and contains. To change contains, start without a cursor."}
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
            "required":["stream","lines","readStatus","truncated","truncatedBeforeFilter","truncatedByTail","nextCursor","error"], "properties":{
                "stream":{"enum":["stdout","stderr","supervisor","maven"]},
                "lines":{"type":"array","items":{"type":"string"}},
                "readStatus":{"enum":["ok","empty","no_matches","missing","error"]},
                "truncated":{"type":"boolean","description":"True when either truncation flag is true."},
                "truncatedBeforeFilter":{"type":"boolean","description":"Older content was outside the 16 KiB window searched for this page."},
                "truncatedByTail":{"type":"boolean","description":"More lines matched inside the search window than tail returned."},
                "nextCursor":{"type":["string","null"],"description":"Continue backward for this stream, even if readStatus is no_matches. Null means pagination was not requested or there are no older pages."},
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
    let cursor = args
        .get("cursor")
        .map(|value| Cursor::parse(value, contains))
        .transpose()?;
    let stream = args
        .get("stream")
        .map(|value| {
            STREAMS.iter().position(|name| value.as_str() == Some(*name))
                .ok_or("stream must be stdout, stderr, supervisor, or maven")
        })
        .transpose()?;
    let paginate = args
        .get("paginate")
        .map(|value| value.as_bool().ok_or("paginate must be a boolean"))
        .transpose()?
        .unwrap_or(false);
    let query = PageQuery {
        execution: &record.execution_id,
        step,
        tail,
        contains,
        stream,
        paginate,
        cursor,
    };
    let streams = query.read(&store.root)?;
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

const STREAMS: [&str; 4] = ["stdout", "stderr", "supervisor", "maven"];

#[derive(Deserialize, Serialize)]
struct Cursor(String, u64, usize, u64, u64, u64, bool, Option<String>);

impl Cursor {
    fn parse(value: &Value, contains: Option<&str>) -> Result<Self, String> {
        let cursor: Self = value
            .as_str()
            .filter(|token| token.len() <= 256)
            .and_then(|token| serde_json::from_str(token).ok())
            .ok_or("Invalid or stale cursor; start without a cursor to obtain a new nextCursor")?;
        if cursor.7 != Self::filter_digest(contains) {
            return Err("Cursor does not match contains; start again without a cursor to change the filter".into());
        }
        Ok(cursor)
    }

    fn filter_digest(contains: Option<&str>) -> Option<String> {
        contains.map(|needle| {
            Sha256::digest(needle.as_bytes())
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect()
        })
    }
}

struct PageQuery<'a> {
    execution: &'a str,
    step: u64,
    tail: usize,
    contains: Option<&'a str>,
    stream: Option<usize>,
    paginate: bool,
    cursor: Option<Cursor>,
}

impl PageQuery<'_> {
    fn read(&self, root: &std::path::Path) -> Result<Vec<Value>, String> {
        let indexes = match &self.cursor {
            Some(Cursor(id, step, index, ..))
                if id == self.execution && *step == self.step && *index < STREAMS.len()
                    && self.stream.is_none_or(|stream| stream == *index) =>
            {
                *index..*index + 1
            }
            Some(_) => return Err("Cursor does not match this execution, step, or stream".into()),
            None => self.stream.map_or(0..STREAMS.len(), |stream| stream..stream + 1),
        };
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(root.join(self.execution));
        Ok(indexes
            .map(|index| {
                let result = directory
                    .as_ref()
                    .map_err(|error| io::Error::from(error.kind()))
                    .and_then(|directory| self.read_stream(directory, index));
                stream_result(STREAMS[index], result)
            })
            .collect())
    }

    fn read_stream(&self, directory: &File, index: usize) -> io::Result<StreamSnapshot> {
        let stream = STREAMS[index];
        let name = if stream == "supervisor" {
            "supervisor.log".into()
        } else {
            format!("{}.{stream}.log", self.step)
        };
        let mut file = open_stream(directory, &name)?;
        let metadata = file.metadata()?;
        let identity = (metadata.dev(), metadata.ino());
        let (end, partial_end) = self.page_end(identity, metadata.len())?;
        let (start, bytes) = read_window(&mut file, end)?;
        let mut snapshot = select_page(&bytes, start, partial_end, self.tail, self.contains);
        if !self.paginate && self.cursor.is_none() {
            return Ok(snapshot);
        }
        snapshot.cursor = snapshot.next.map(|(offset, partial)| {
            serde_json::to_string(&Cursor(
                self.execution.into(),
                self.step,
                index,
                identity.0,
                identity.1,
                offset,
                partial,
                Cursor::filter_digest(self.contains),
            ))
            .expect("cursor contains only primitive values")
        });
        Ok(snapshot)
    }

    fn page_end(&self, identity: (u64, u64), length: u64) -> io::Result<(u64, bool)> {
        match self.cursor {
            Some(Cursor(_, _, _, dev, ino, end, partial, _))
                if (dev, ino) == identity && end > 0 && end <= length =>
            {
                Ok((end, partial))
            }
            Some(_) => Err(io::Error::other(
                "Log changed; start again without a cursor",
            )),
            None => Ok((length, false)),
        }
    }
}

fn read_window(file: &mut File, end: u64) -> io::Result<(u64, Vec<u8>)> {
    let start = end.saturating_sub(STREAM_BYTES);
    let offset = start.saturating_sub(1);
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = vec![0; (end - offset) as usize];
    file.read_exact(&mut bytes)?;
    Ok((offset, bytes))
}

struct StreamSnapshot {
    lines: Vec<String>,
    status: &'static str,
    clipped: bool,
    limited: bool,
    next: Option<(u64, bool)>,
    cursor: Option<String>,
}

fn complete_line_bounds(bytes: &[u8], offset: u64, partial_end: bool) -> (usize, usize) {
    let end = if partial_end {
        bytes
            .iter()
            .rposition(|byte| *byte == b'\n')
            .map_or(0, |i| i + 1)
    } else {
        bytes.len()
    };
    // A nonzero offset includes one lookbehind byte to detect a line boundary.
    let start = if offset > 0 || bytes.len() as u64 > STREAM_BYTES {
        bytes[..end]
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(end, |i| i + 1)
    } else {
        0
    };
    (start, end)
}

fn select_page(
    bytes: &[u8],
    offset: u64,
    partial_end: bool,
    tail: usize,
    contains: Option<&str>,
) -> StreamSnapshot {
    let (start, end) = complete_line_bounds(bytes, offset, partial_end);
    let clipped = offset + start as u64 > 0;
    let mut position = offset + end as u64;
    let mut matched = bytes[start..end]
        .split_inclusive(|byte| *byte == b'\n')
        .rev()
        .filter_map(|raw| {
            position -= raw.len() as u64;
            let line = String::from_utf8_lossy(raw);
            let line = line.lines().next().unwrap_or("");
            contains
                .is_none_or(|needle| line.contains(needle))
                .then(|| (position, line.to_owned()))
        });
    let selected: Vec<_> = matched.by_ref().take(tail).collect();
    let limited = matched.next().is_some();
    let next = if limited {
        selected.last().map(|(position, _)| (*position, false))
    } else if start > 0 && start < bytes.len() {
        Some((offset + start as u64, false))
    } else {
        (offset > 0).then_some((offset, true))
    };
    let lines: Vec<_> = selected.into_iter().rev().map(|(_, line)| line).collect();
    let status = match (bytes.is_empty(), lines.is_empty(), contains.is_some()) {
        (true, _, _) => "empty",
        (_, true, true) => "no_matches",
        (_, true, false) => "empty",
        _ => "ok",
    };
    StreamSnapshot {
        lines,
        status,
        clipped,
        limited,
        next,
        cursor: None,
    }
}

fn stream_result(stream: &str, result: io::Result<StreamSnapshot>) -> Value {
    let (lines, status, clipped, limited, cursor, error) = match result {
        Ok(snapshot) => (
            snapshot.lines,
            snapshot.status,
            snapshot.clipped,
            snapshot.limited,
            snapshot.cursor,
            None,
        ),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            (vec![], "missing", false, false, None, None)
        }
        Err(error) => (vec![], "error", false, false, None, Some(error.to_string())),
    };
    json!({"stream":stream,"lines":lines,"readStatus":status,"truncated":clipped || limited,
        "truncatedBeforeFilter":clipped,"truncatedByTail":limited,"nextCursor":cursor,"error":error})
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
    let mut options = options.iter();
    while let Some(flag) = options.next() {
        if flag == "--paginate" {
            args["paginate"] = json!(true);
            continue;
        }
        let value = options.next().ok_or(HELP)?;
        let value = value.to_str().ok_or("option values must be UTF-8")?;
        match flag.to_str() {
            Some("--step") => {
                args["step"] = json!(value.parse::<u64>().map_err(|_| "invalid step")?)
            }
            Some("--tail") => {
                args["tail"] = json!(value.parse::<u64>().map_err(|_| "invalid tail")?)
            }
            Some("--contains") => args["contains"] = json!(value),
            Some("--stream") => args["stream"] = json!(value),
            Some("--cursor") => args["cursor"] = json!(value),
            _ => return Err(HELP.into()),
        }
    }
    Ok(args)
}

#[cfg(test)]
#[path = "execution_logs_test.rs"]
mod tests;
