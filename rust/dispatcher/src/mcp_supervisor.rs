use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::mcp_execution::{now_ms, save_record, ExecutionRecord};
use crate::mcp_server::{handle_tool_call, ToolCallResult};

#[derive(Deserialize, Serialize)]
struct SupervisorConfig {
    root: PathBuf,
    record: ExecutionRecord,
    params: Value,
    backend: PathBuf,
    lock_fds: Vec<i32>,
}

static WORKER: OnceLock<Arc<ExecutionWorker>> = OnceLock::new();

struct ExecutionWorker {
    root: PathBuf,
    record: Mutex<ExecutionRecord>,
    cancelled: AtomicBool,
    cancellation_started: OnceLock<Instant>,
    command_index: AtomicUsize,
}

pub fn spawn(
    executable: &std::path::Path,
    backend: &std::path::Path,
    root: PathBuf,
    record: ExecutionRecord,
    params: Value,
    locks: Vec<File>,
) -> Result<(Child, ChildStdin), String> {
    let lock_fds: Vec<_> = locks.iter().map(AsRawFd::as_raw_fd).collect();
    let config = SupervisorConfig {
        root: root.clone(),
        record: record.clone(),
        params,
        backend: backend.into(),
        lock_fds: lock_fds.clone(),
    };
    let mut command = Command::new(executable);
    command
        .arg("--makevn-mcp-supervisor")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(capture_file(
            &root.join(&record.execution_id).join("supervisor.log"),
        )?)
        .process_group(0);
    unsafe {
        command.pre_exec(move || {
            for fd in &lock_fds {
                if libc::fcntl(*fd, libc::F_SETFD, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    let mut child = command.spawn().map_err(|error| error.to_string())?;
    let mut ownership = child
        .stdin
        .take()
        .ok_or("missing supervisor ownership pipe")?;
    let configuration = serde_json::to_string(&config).map_err(|error| error.to_string())?;
    if let Err(error) = writeln!(ownership, "{configuration}") {
        drop(ownership);
        let _ = child.wait();
        return Err(error.to_string());
    }
    // The supervisor inherited the same locked open file descriptions.
    drop(locks);
    Ok((child, ownership))
}

pub fn run() -> Result<i32, String> {
    let mut input = io::BufReader::new(io::stdin());
    let mut line = String::new();
    input
        .read_line(&mut line)
        .map_err(|error| error.to_string())?;
    let config: SupervisorConfig =
        serde_json::from_str(&line).map_err(|error| error.to_string())?;
    let locks: Vec<File> = config
        .lock_fds
        .iter()
        .map(|fd| unsafe { File::from_raw_fd(*fd) })
        .collect();
    mark_close_on_exec(&locks)?;
    let worker = Arc::new(ExecutionWorker {
        root: config.root,
        record: Mutex::new(config.record),
        cancelled: AtomicBool::new(false),
        cancellation_started: OnceLock::new(),
        command_index: AtomicUsize::new(0),
    });
    WORKER
        .set(worker.clone())
        .map_err(|_| "supervisor already initialized")?;
    let result = if admit(&mut input, &worker)? {
        watch_owner(input, worker.clone());
        handle_tool_call(&config.backend, &config.params).unwrap_or_else(ToolCallResult::failure)
    } else {
        ToolCallResult::failure("Execution cancelled before starting".into())
    };
    finish(&worker, result, locks)
}

fn admit(input: &mut impl Read, worker: &ExecutionWorker) -> Result<bool, String> {
    let mut byte = [0];
    if input.read_exact(&mut byte).is_err() || byte[0] != b'S' {
        worker.cancel();
        return Ok(false);
    }
    worker.update(|record| record.state = "running".into())?;
    Ok(true)
}

fn mark_close_on_exec(locks: &[File]) -> Result<(), String> {
    for lock in locks {
        if unsafe { libc::fcntl(lock.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } == -1 {
            return Err(io::Error::last_os_error().to_string());
        }
    }
    Ok(())
}

fn watch_owner(mut input: impl Read + Send + 'static, worker: Arc<ExecutionWorker>) {
    thread::spawn(move || {
        let mut byte = [0];
        let _ = input.read(&mut byte);
        worker.cancel();
        thread::sleep(Duration::from_secs(7));
        if !worker.record.lock().unwrap().terminal() {
            eprintln!("Owned process cleanup exceeded seven seconds; retaining execution locks until termination is confirmed");
        }
    });
}

fn finish(
    worker: &ExecutionWorker,
    mut result: ToolCallResult,
    locks: Vec<File>,
) -> Result<i32, String> {
    let mut record = worker.record.lock().unwrap();
    if worker.cancelled.load(Ordering::SeqCst) {
        result.exit_code = 130;
        result.next_suggestion = Some(
            "Execution cancelled; inspect its logs before starting another verification.".into(),
        );
        record.state = "cancelled".into();
    } else {
        record.state = if result.exit_code == 0 {
            "succeeded"
        } else {
            "failed"
        }
        .into();
    }
    record.exit_code = Some(result.exit_code);
    record.duration_ms = now_ms().saturating_sub(record.started_at_ms);
    record.current_phase = None;
    result.duration_ms = u128::from(record.duration_ms);
    save_record(&worker.root, &record)?;
    drop(locks);
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, &result).map_err(|error| error.to_string())?;
    stdout.flush().map_err(|error| error.to_string())?;
    Ok(0)
}

impl ExecutionWorker {
    fn update(&self, change: impl FnOnce(&mut ExecutionRecord)) -> Result<(), String> {
        let mut record = self.record.lock().unwrap();
        change(&mut record);
        save_record(&self.root, &record)
    }

    fn cancel(&self) {
        let mut record = self.record.lock().unwrap();
        if record.terminal() {
            return;
        }
        self.cancellation_started.get_or_init(Instant::now);
        self.cancelled.store(true, Ordering::SeqCst);
        record.state = "cancelling".into();
        let _ = save_record(&self.root, &record);
    }

    fn paths(&self) -> Result<(PathBuf, PathBuf, PathBuf), String> {
        let index = self.command_index.fetch_add(1, Ordering::SeqCst);
        let id = self.record.lock().unwrap().execution_id.clone();
        let directory = self.root.join(id);
        let stdout = directory.join(format!("{index}.stdout.log"));
        let stderr = directory.join(format!("{index}.stderr.log"));
        let phase = directory.join(format!("{index}.phase"));
        self.update(|record| {
            record.log_paths.extend([
                stdout.to_string_lossy().into_owned(),
                stderr.to_string_lossy().into_owned(),
            ]);
        })?;
        Ok((stdout, stderr, phase))
    }

    fn refresh(&self, output: &str, phase: &std::path::Path) {
        let (_, paths) = crate::mcp_server::extract_log_headers(output);
        let phase = fs::read_to_string(phase)
            .ok()
            .and_then(|phase| phase.lines().next().map(str::to_owned));
        let mut record = self.record.lock().unwrap();
        let previous_phase = record.current_phase.clone();
        let previous_paths = record.log_paths.len();
        record.current_phase = phase;
        for path in paths {
            if !record.log_paths.contains(&path) {
                record.log_paths.push(path);
            }
        }
        if record.current_phase != previous_phase || record.log_paths.len() != previous_paths {
            let _ = save_record(&self.root, &record);
        }
    }
}

pub fn cancelled() -> bool {
    WORKER
        .get()
        .is_some_and(|worker| worker.cancelled.load(Ordering::SeqCst))
}

pub fn command_output(command: &mut Command, detached: bool) -> Result<Output, String> {
    let Some(worker) = WORKER.get() else {
        return command.output().map_err(|error| error.to_string());
    };
    if cancelled() {
        return Err("Execution cancelled before starting the next step".into());
    }
    let (stdout, stderr, phase) = worker.paths()?;
    let mut child = spawn_captured(command, &stdout, &stderr, &phase)?;
    let group = child.id() as i32;
    let mut tail = OutputTail::default();
    let status = wait_command(worker, &mut child, &stdout, &phase, &mut tail)?;
    if !detached {
        clean_group(worker, group);
    }
    worker.refresh(&tail.read(&stdout), &phase);
    captured_output(status, &stdout, &stderr)
}

fn spawn_captured(
    command: &mut Command,
    stdout: &std::path::Path,
    stderr: &std::path::Path,
    phase: &std::path::Path,
) -> Result<Child, String> {
    command
        .stdin(Stdio::null())
        .stdout(capture_file(stdout)?)
        .stderr(capture_file(stderr)?)
        .env("MAKEVN_MCP_PHASE_OUT", phase)
        .process_group(0);
    command.spawn().map_err(|error| error.to_string())
}

fn captured_output(
    status: std::process::ExitStatus,
    stdout: &std::path::Path,
    stderr: &std::path::Path,
) -> Result<Output, String> {
    Ok(Output {
        status,
        stdout: fs::read(stdout).map_err(|error| error.to_string())?,
        stderr: fs::read(stderr).map_err(|error| error.to_string())?,
    })
}

#[derive(Default)]
struct OutputTail {
    offset: u64,
    pending: String,
}

impl OutputTail {
    fn read(&mut self, path: &std::path::Path) -> String {
        let Ok(mut file) = File::open(path) else {
            return String::new();
        };
        if file.seek(SeekFrom::Start(self.offset)).is_err() {
            return String::new();
        }
        let mut added = String::new();
        if file.read_to_string(&mut added).is_err() {
            return String::new();
        }
        self.offset += added.len() as u64;
        self.pending.push_str(&added);
        let Some(end) = self.pending.rfind('\n') else {
            return String::new();
        };
        let remainder = self.pending.split_off(end + 1);
        std::mem::replace(&mut self.pending, remainder)
    }
}

fn capture_file(path: &std::path::Path) -> Result<File, String> {
    OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| error.to_string())
}

fn wait_command(
    worker: &ExecutionWorker,
    child: &mut Child,
    stdout: &std::path::Path,
    phase: &std::path::Path,
    tail: &mut OutputTail,
) -> Result<std::process::ExitStatus, String> {
    let mut termination_sent = false;
    let mut refreshed = Instant::now() - Duration::from_secs(1);
    loop {
        if cancelled() {
            signal_cancellation(worker, child.id() as i32, &mut termination_sent);
        }
        if let Some(status) = child.try_wait().map_err(|error| error.to_string())? {
            return Ok(status);
        }
        if refreshed.elapsed() >= Duration::from_secs(1) {
            worker.refresh(&tail.read(stdout), phase);
            refreshed = Instant::now();
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn signal_cancellation(worker: &ExecutionWorker, group: i32, sent: &mut bool) {
    if !*sent {
        signal_group(group, libc::SIGTERM);
        *sent = true;
    }
    if worker
        .cancellation_started
        .get()
        .is_some_and(|start| start.elapsed() >= Duration::from_secs(5))
    {
        signal_group(group, libc::SIGKILL);
    }
}

fn signal_group(group: i32, signal: i32) {
    // Groups are created by this supervisor; no process-name or checkout matching.
    unsafe {
        libc::kill(-group, signal);
    }
}

fn clean_group(worker: &ExecutionWorker, group: i32) {
    if !group_alive(group) {
        return;
    }
    let start = worker
        .cancellation_started
        .get()
        .copied()
        .unwrap_or_else(Instant::now);
    signal_group(group, libc::SIGTERM);
    while group_alive(group) {
        if start.elapsed() >= Duration::from_secs(5) {
            signal_group(group, libc::SIGKILL);
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn group_alive(group: i32) -> bool {
    if unsafe { libc::kill(-group, 0) } != 0 {
        return false;
    }
    // Reparented zombies cannot run; do not retain locks waiting for init to reap them.
    let Ok(output) = Command::new("ps").args(["-axo", "pgid=,stat="]).output() else {
        return true;
    };
    if !output.status.success() {
        return true;
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|line| live_group_member(line, group))
}

fn live_group_member(line: &str, group: i32) -> bool {
    let mut fields = line.split_whitespace();
    fields.next().and_then(|field| field.parse::<i32>().ok()) == Some(group)
        && fields.next().is_some_and(|state| !state.starts_with('Z'))
}

#[cfg(test)]
#[path = "mcp_supervisor_test.rs"]
mod tests;
