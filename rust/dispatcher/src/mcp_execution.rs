use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecutionRecord {
    pub execution_id: String,
    pub session_id: String,
    pub command: String,
    pub repo: String,
    pub pr: Option<String>,
    pub repositories: Vec<String>,
    pub pull_requests: Vec<String>,
    pub started_at_ms: u64,
    pub duration_ms: u64,
    pub state: String,
    pub log_paths: Vec<String>,
    pub exit_code: Option<i32>,
    pub current_phase: Option<String>,
}

impl ExecutionRecord {
    pub fn terminal(&self) -> bool {
        matches!(self.state.as_str(), "succeeded" | "failed" | "cancelled")
    }

    pub fn snapshot(mut self) -> Self {
        if !self.terminal() {
            self.duration_ms = now_ms().saturating_sub(self.started_at_ms);
        }
        self
    }
}

pub fn record_schema() -> Value {
    json!({
        "type":"object",
        "required":["executionId","sessionId","command","repo","pr","repositories","pullRequests","startedAtMs","durationMs","state","logPaths","exitCode","currentPhase"],
        "properties": {
            "executionId":{"type":"string"}, "sessionId":{"type":"string"},
            "command":{"type":"string"}, "repo":{"type":"string"},
            "pr":{"type":["string","null"]},
            "repositories":{"type":"array","items":{"type":"string"}},
            "pullRequests":{"type":"array","items":{"type":"string"}},
            "startedAtMs":{"type":"integer","minimum":0}, "durationMs":{"type":"integer","minimum":0},
            "state":{"enum":["queued","running","cancelling","succeeded","failed","cancelled"]},
            "logPaths":{"type":"array","items":{"type":"string"}},
            "exitCode":{"type":["integer","null"]}, "currentPhase":{"type":["string","null"]}
        }
    })
}

pub struct ExecutionStore {
    pub root: PathBuf,
    pub session_id: String,
}

impl ExecutionStore {
    pub fn new() -> Result<Self, String> {
        let state = std::env::var_os("XDG_STATE_HOME")
            .filter(|path| !path.is_empty())
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state"))
            })
            .ok_or("HOME or XDG_STATE_HOME is required for the execution registry")?;
        let root = state.join("makevn/executions");
        private_directory(&root)?;
        private_directory(&root.join("locks"))?;
        Ok(Self {
            root,
            session_id: new_id()?,
        })
    }

    pub fn prepare(&self, params: &Value) -> Result<(ExecutionRecord, Vec<File>), String> {
        crate::execution_retention::automatic(self)?;
        let mut record = prepare_record(&self.session_id, params)?;
        let _admission = registry_admission(&self.root)?;
        let mut locks = acquire_locks(&self.root, &record, params)?;
        private_directory(&self.root.join(&record.execution_id))?;
        locks.push(acquire_lock(
            &self.root.join(&record.execution_id).join("lifetime.lock"),
            "lifetime",
            &record,
        )?);
        record.log_paths.push(
            self.root
                .join(&record.execution_id)
                .join("supervisor.log")
                .to_string_lossy()
                .into_owned(),
        );
        save_record(&self.root, &record)?;
        Ok((record, locks))
    }

    pub fn get(&self, id: &str) -> Result<ExecutionRecord, String> {
        validate_id(id)?;
        self.reconcile(&self.root.join(format!("{id}.json")))
    }

    fn reconcile(&self, path: &Path) -> Result<ExecutionRecord, String> {
        let record = read_record(path)?;
        if record.terminal() {
            return Ok(record);
        }
        let _admission = registry_admission(&self.root)?;
        let mut record = read_record(path)?;
        if record.terminal() || lifetime_active(&self.root, &record)? {
            return Ok(record);
        }
        record.state = "failed".into();
        record.duration_ms = now_ms().saturating_sub(record.started_at_ms);
        record.current_phase = None;
        save_record(&self.root, &record)?;
        Ok(record)
    }

    pub fn list(&self, params: &Value) -> Result<Vec<ExecutionRecord>, String> {
        let repo = params["repo"].as_str().map(canonical_repo).transpose()?;
        let finished = params["includeFinished"].as_bool().unwrap_or(false);
        let mut records = Vec::new();
        for entry in fs::read_dir(&self.root).map_err(|error| error.to_string())? {
            let path = entry.map_err(|error| error.to_string())?.path();
            if path
                .extension()
                .is_some_and(|extension| extension == "json")
            {
                let record = self.reconcile(&path)?.snapshot();
                if visible_record(&record, repo.as_deref(), finished) {
                    records.push(record);
                }
            }
        }
        records.sort_by_key(|record| record.started_at_ms);
        Ok(records)
    }
}

fn lifetime_active(root: &Path, record: &ExecutionRecord) -> Result<bool, String> {
    let path = root.join(&record.execution_id).join("lifetime.lock");
    let file = match OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        // Older registries lack ownership evidence; do not infer liveness from PIDs.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(true),
        Err(error) => return Err(error.to_string()),
    };
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(false);
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::WouldBlock {
        Ok(true)
    } else {
        Err(error.to_string())
    }
}

fn visible_record(record: &ExecutionRecord, repo: Option<&str>, finished: bool) -> bool {
    (finished || !record.terminal())
        && repo.is_none_or(|repo| record.repositories.iter().any(|path| path == repo))
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

pub fn new_id() -> Result<String, String> {
    let mut bytes = [0_u8; 16];
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|error| error.to_string())?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub(crate) fn validate_id(id: &str) -> Result<(), String> {
    if id.len() != 32 || !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("invalid executionId".into());
    }
    Ok(())
}

pub fn private_directory(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path).map_err(|error| error.to_string())?;
    let metadata = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    if !metadata.is_dir() {
        return Err("execution registry must be a directory, not a symlink".into());
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| error.to_string())
}

pub fn save_record(root: &Path, record: &ExecutionRecord) -> Result<(), String> {
    let path = root.join(format!("{}.json", record.execution_id));
    let temporary = root.join(format!("{}.tmp", record.execution_id));
    let bytes = serde_json::to_vec(record).map_err(|error| error.to_string())?;
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temporary)
        .map_err(|error| error.to_string())?;
    file.write_all(&bytes).map_err(|error| error.to_string())?;
    fs::rename(temporary, path).map_err(|error| error.to_string())
}

pub(crate) fn read_record(path: &Path) -> Result<ExecutionRecord, String> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| format!("execution not found or unreadable: {error}"))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    serde_json::from_slice(&bytes).map_err(|error| error.to_string())
}

pub fn canonical_repo(repo: &str) -> Result<String, String> {
    let path = fs::canonicalize(repo).map_err(|error| format!("invalid repository: {error}"))?;
    if !path.is_dir() {
        return Err("repo must be a directory".into());
    }
    let root = path
        .ancestors()
        .find(|ancestor| ancestor.join(".git").exists())
        .unwrap_or(&path);
    Ok(root.to_string_lossy().into_owned())
}

pub fn normalize_pr(pr: &str) -> Result<String, String> {
    let remainder = pr
        .strip_prefix("https://")
        .or_else(|| pr.strip_prefix("http://"))
        .ok_or("pr must be an HTTP(S) pull request URL")?;
    let (host, path) = remainder
        .split_once('/')
        .ok_or("pr must include a pull request path")?;
    if host.is_empty()
        || !host
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b".-:".contains(&byte))
    {
        return Err("invalid pull request host".into());
    }
    let parts: Vec<_> = path.trim_end_matches('/').split('/').collect();
    validate_pr_path(&parts)?;
    let number: u64 = parts[3]
        .parse()
        .map_err(|_| "invalid pull request number")?;
    if number == 0 {
        return Err("pull request number must be positive".into());
    }
    let host = host
        .trim_end_matches(":443")
        .trim_end_matches(":80")
        .to_ascii_lowercase();
    Ok(format!(
        "https://{}/{}/{}/pull/{number}",
        host,
        parts[0].to_ascii_lowercase(),
        parts[1].to_ascii_lowercase()
    ))
}

fn validate_pr_path(parts: &[&str]) -> Result<(), String> {
    if parts.len() != 4 || parts[2] != "pull" {
        return Err("pr must have the path /owner/repository/pull/number".into());
    }
    for part in &parts[..2] {
        if part.is_empty()
            || !part
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
        {
            return Err("invalid pull request repository".into());
        }
    }
    Ok(())
}

fn prepare_record(session: &str, params: &Value) -> Result<ExecutionRecord, String> {
    let repo = effective_repo(&params["arguments"], None)?;
    let pr = params["arguments"]
        .get("pr")
        .and_then(Value::as_str)
        .map(normalize_pr)
        .transpose()?;
    let mut record = ExecutionRecord {
        execution_id: new_id()?,
        session_id: session.into(),
        command: params["name"].as_str().unwrap_or_default().into(),
        repo: repo.clone(),
        pr: pr.clone(),
        repositories: vec![repo],
        pull_requests: pr.into_iter().collect(),
        started_at_ms: now_ms(),
        duration_ms: 0,
        state: "queued".into(),
        log_paths: vec![],
        exit_code: None,
        current_phase: None,
    };
    for step in workflow_steps(params) {
        record
            .repositories
            .push(effective_repo(&step["arguments"], Some(&record.repo))?);
        if let Some(pr) = step["arguments"]["pr"].as_str() {
            record.pull_requests.push(normalize_pr(pr)?);
        }
    }
    record.repositories.sort();
    record.repositories.dedup();
    record.pull_requests.sort();
    record.pull_requests.dedup();
    Ok(record)
}

fn effective_repo(args: &Value, fallback: Option<&str>) -> Result<String, String> {
    let cwd = std::env::current_dir().map_err(|error| error.to_string())?;
    let repo = args["repo"]
        .as_str()
        .filter(|repo| !repo.is_empty())
        .or(fallback);
    canonical_repo(repo.unwrap_or(&cwd.to_string_lossy()))
}

fn workflow_steps(params: &Value) -> &[Value] {
    params["arguments"]["steps"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
}

pub fn inspection(tool: &str) -> bool {
    matches!(
        tool,
        "doctor"
            | "verify_changes_preview"
            | "docker_ps"
            | "docker_stats"
            | "docker_ps_required"
            | "jdk_current"
            | "jdk_list"
    )
}

fn conflict_keys(record: &ExecutionRecord, params: &Value) -> Vec<String> {
    let steps = workflow_steps(params);
    if inspection(&record.command) {
        return vec![];
    }
    if !steps.is_empty()
        && steps
            .iter()
            .all(|step| inspection(step["tool"].as_str().unwrap_or_default()))
    {
        return vec![];
    }
    let mut keys: Vec<_> = record
        .repositories
        .iter()
        .map(|repo| format!("worktree:{repo}"))
        .collect();
    keys.extend(record.pull_requests.iter().map(|pr| format!("pr:{pr}")));
    keys.sort();
    keys.dedup();
    keys
}

fn lock_name(key: &str) -> String {
    // Deterministic across server processes; the full key is retained in the file.
    let hash = key.bytes().fold(0xcbf29ce484222325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3)
    });
    format!("{hash:016x}.lock")
}

fn acquire_locks(
    root: &Path,
    record: &ExecutionRecord,
    params: &Value,
) -> Result<Vec<File>, String> {
    let mut locks = Vec::new();
    for key in conflict_keys(record, params) {
        locks.push(acquire_lock(
            &root.join("locks").join(lock_name(&key)),
            &key,
            record,
        )?);
    }
    Ok(locks)
}

fn acquire_lock(path: &Path, key: &str, record: &ExecutionRecord) -> Result<File, String> {
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| error.to_string())?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::WouldBlock {
            return Err(error.to_string());
        }
        let mut owner = String::new();
        file.read_to_string(&mut owner)
            .map_err(|error| error.to_string())?;
        return Err(format!("Execution conflict for {key}; active execution owner: {owner}. Inspect its executionId before retrying."));
    }
    let owner =
        json!({"executionId": record.execution_id, "sessionId": record.session_id, "key": key});
    file.set_len(0)
        .and_then(|()| file.seek(SeekFrom::Start(0)))
        .and_then(|_| file.write_all(owner.to_string().as_bytes()))
        .map_err(|error| error.to_string())?;
    Ok(file)
}

pub(crate) fn registry_admission(root: &Path) -> Result<File, String> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(root.join("admission.lock"))
        .map_err(|error| error.to_string())?;
    let start = Instant::now();
    while unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::WouldBlock {
            return Err(error.to_string());
        }
        if start.elapsed() >= Duration::from_millis(100) {
            return Err("Execution registry admission is busy; no command was started".into());
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    Ok(file)
}

#[cfg(test)]
#[path = "mcp_execution_test.rs"]
mod tests;
