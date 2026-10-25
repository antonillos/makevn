use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::mcp_execution::{now_ms, read_record, registry_admission, validate_id, ExecutionStore};

const DAY_MS: u64 = 86_400_000;

fn retention_days(args: &Value) -> Result<u64, String> {
    let days = match args.get("retentionDays") {
        Some(value) => value
            .as_u64()
            .ok_or("retentionDays must be a positive integer")?,
        None => std::env::var("MAKEVN_RETENTION_DAYS")
            .unwrap_or_else(|_| "3".into())
            .parse::<u64>()
            .map_err(|_| "MAKEVN_RETENTION_DAYS must be a positive integer")?,
    };
    if days == 0 || days.checked_mul(DAY_MS).is_none() {
        return Err("retention days must be positive and fit in milliseconds".into());
    }
    Ok(days)
}

pub fn automatic(store: &ExecutionStore) {
    let _ = cleanup(store, &json!({}));
}

pub fn cleanup(store: &ExecutionStore, args: &Value) -> Result<Value, String> {
    let days = retention_days(args)?;
    let dry_run = match args.get("dryRun") {
        Some(value) => value.as_bool().ok_or("dryRun must be a boolean")?,
        None => false,
    };
    cleanup_at(store, days, dry_run, now_ms())
}

fn cleanup_at(store: &ExecutionStore, days: u64, dry_run: bool, now: u64) -> Result<Value, String> {
    let _admission = registry_admission(&store.root)?;
    let mut executions = Vec::new();
    let mut logs = Vec::new();
    for entry in fs::read_dir(&store.root).map_err(|error| error.to_string())? {
        let path = entry.map_err(|error| error.to_string())?.path();
        if let Some((id, paths)) = cleanup_execution(&path, days, dry_run, now)? {
            executions.push(id);
            logs.extend(paths);
        }
    }
    executions.sort();
    logs.sort();
    Ok(json!({"retentionDays":days,"dryRun":dry_run,
        "executionsDeleted":if dry_run {0} else {executions.len()},
        "logsDeleted":if dry_run {0} else {logs.len()},
        "executionIds":executions,"logPaths":logs}))
}

fn cleanup_execution(
    path: &Path,
    days: u64,
    dry_run: bool,
    now: u64,
) -> Result<Option<(String, Vec<String>)>, String> {
    let Some(id) = expired_id(path, days, now) else {
        return Ok(None);
    };
    let directory = path.parent().ok_or("missing execution registry")?.join(&id);
    let Some(_lifetime) = inactive_lock(&directory)? else {
        return Ok(None);
    };
    let Some(files) = owned_files(&directory)? else {
        return Ok(None);
    };
    let logs = files
        .iter()
        .filter(|path| path.extension().is_some_and(|extension| extension == "log"))
        .map(|path| path.to_string_lossy().into_owned())
        .collect();
    if !dry_run {
        remove_execution(path, &directory, files)?;
    }
    Ok(Some((id, logs)))
}

fn remove_execution(record: &Path, directory: &Path, files: Vec<PathBuf>) -> Result<(), String> {
    for file in files {
        fs::remove_file(file).map_err(|error| error.to_string())?;
    }
    fs::remove_dir(directory).map_err(|error| error.to_string())?;
    fs::remove_file(record).map_err(|error| error.to_string())
}

fn expired_id(path: &Path, days: u64, now: u64) -> Option<String> {
    let (id, record) = registered_record(path)?;
    let old =
        now.saturating_sub(record.started_at_ms.saturating_add(record.duration_ms)) > days * DAY_MS;
    (record.terminal() && old).then_some(id)
}

fn registered_record(path: &Path) -> Option<(String, crate::mcp_execution::ExecutionRecord)> {
    let id = record_id(path)?;
    if !regular_record(path) {
        return None;
    }
    let record = read_record(path).ok()?;
    (record.execution_id == id).then(|| (id.to_owned(), record))
}

fn record_id(path: &Path) -> Option<&str> {
    let id = path.file_stem()?.to_str()?;
    (path.extension()? == "json" && validate_id(id).is_ok()).then_some(id)
}

fn regular_record(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.is_file())
}

fn inactive_lock(directory: &Path) -> Result<Option<File>, String> {
    let Ok(metadata) = fs::symlink_metadata(directory) else {
        return Ok(None);
    };
    if !metadata.is_dir() {
        return Ok(None);
    }
    let file = match OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(directory.join("lifetime.lock"))
    {
        Ok(file) => file,
        Err(_) => return Ok(None),
    };
    try_inactive_lock(file)
}

fn try_inactive_lock(file: File) -> Result<Option<File>, String> {
    if !file
        .metadata()
        .map_err(|error| error.to_string())?
        .is_file()
    {
        return Ok(None);
    }
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(Some(file));
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::WouldBlock {
        Ok(None)
    } else {
        Err(error.to_string())
    }
}

fn owned_files(directory: &Path) -> Result<Option<Vec<PathBuf>>, String> {
    let mut files = Vec::new();
    for entry in fs::read_dir(directory).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !entry
            .file_type()
            .map_err(|error| error.to_string())?
            .is_file()
            || !owned_name(&name)
        {
            return Ok(None);
        }
        files.push(entry.path());
    }
    Ok(Some(files))
}

fn owned_name(name: &str) -> bool {
    if matches!(name, "lifetime.lock" | "supervisor.log") {
        return true;
    }
    [".stdout.log", ".stderr.log", ".phase"]
        .iter()
        .any(|suffix| {
            name.strip_suffix(suffix).is_some_and(|index| {
                !index.is_empty() && index.bytes().all(|byte| byte.is_ascii_digit())
            })
        })
}

pub fn schema() -> Value {
    json!({"type":"object","required":["retentionDays","dryRun","executionsDeleted","logsDeleted","executionIds","logPaths"],
        "properties":{"retentionDays":{"type":"integer"},"dryRun":{"type":"boolean"},
        "executionsDeleted":{"type":"integer"},"logsDeleted":{"type":"integer"},
        "executionIds":{"type":"array","items":{"type":"string"}},"logPaths":{"type":"array","items":{"type":"string"}}},"additionalProperties":false})
}

pub fn cli(args: Vec<OsString>) -> Result<(), String> {
    let Some(options) = parse_cli(args)? else {
        crate::cli_help::print_command_help("execution-cleanup");
        return Ok(());
    };
    retention_days(&options)?;
    println!("{}", cleanup(&ExecutionStore::new()?, &options)?);
    Ok(())
}

fn parse_cli(args: Vec<OsString>) -> Result<Option<Value>, String> {
    let mut options = json!({});
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--help" | "-h") => return Ok(None),
            Some("--dry-run") => options["dryRun"] = json!(true),
            Some("--retention-days") => {
                let value = args.next().ok_or("Missing value for --retention-days")?;
                options["retentionDays"] = json!(value
                    .to_str()
                    .and_then(|value| value.parse::<u64>().ok())
                    .ok_or("Invalid --retention-days")?);
            }
            _ => {
                return Err(format!(
                    "Unknown execution-cleanup option: {}",
                    arg.to_string_lossy()
                ))
            }
        }
    }
    Ok(Some(options))
}

#[cfg(test)]
#[path = "execution_retention_test.rs"]
mod tests;
