use std::collections::{BTreeSet, HashMap};
use std::io::{self, BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Command};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;

use serde_json::{json, Value};

use crate::mcp_execution::{effective_repo, inspection, save_record, ExecutionRecord, ExecutionStore};
use crate::mcp_server::{self, ToolCallResult};
use crate::mcp_supervisor;

enum Event {
    Request(Value),
    InputClosed,
    InputFailed(String),
    Start(String),
    Completed {
        id: Value,
        params: Value,
        execution_id: String,
        result: ToolCallResult,
    },
}

struct ActiveExecution {
    request_id: Value,
    ownership: ChildStdin,
    suppress_response: bool,
    cancellation_requested: bool,
}

struct McpSession {
    store: ExecutionStore,
    executable: PathBuf,
    backend: PathBuf,
    active: HashMap<String, ActiveExecution>,
    daemon_groups: HashMap<String, mcp_supervisor::DaemonGroup>,
    sender: mpsc::Sender<Event>,
    stopping: bool,
}

pub fn run(executable: PathBuf, backend: PathBuf) -> Result<i32, String> {
    let (sender, receiver) = mpsc::channel();
    read_requests(sender.clone());
    let interrupted = Arc::new(AtomicBool::new(false));
    for signal in [libc::SIGINT, libc::SIGTERM] {
        signal_hook::flag::register(signal, interrupted.clone())
            .map_err(|error| error.to_string())?;
    }
    let mut session = McpSession {
        store: ExecutionStore::new()?,
        executable,
        backend,
        active: HashMap::new(),
        daemon_groups: HashMap::new(),
        sender,
        stopping: false,
    };
    crate::execution_retention::automatic(&session.store);
    session.serve(receiver, interrupted)
}

fn apply_daemon_preference(args: &mut Value, repo: &str, backend: &Path) -> Result<(), String> {
    if args.get("mvnd").is_some() {
        return Ok(());
    }
    let names = args["name"].as_str().unwrap_or_default().split(',');
    if names.filter(|name| !name.trim().is_empty()).count() == 1 && preferred_daemon(repo, backend) {
        args["mvnd"] = json!(true);
        mcp_server::validate_daemon_test_arguments("test", args)?;
    }
    Ok(())
}

fn daemon_worktrees(params: &mut Value, repo: &str, backend: &Path) -> Result<BTreeSet<String>, String> {
    if params["name"] == "test" {
        let args = &mut params["arguments"];
        apply_daemon_preference(args, repo, backend)?;
        if args["mvnd"] == true {
            args["repo"] = json!(repo);
            return Ok(BTreeSet::from([repo.to_owned()]));
        }
        return Ok(BTreeSet::new());
    }
    let parallel = params["name"] == "parallel_run";
    let Some(steps) = params.pointer_mut("/arguments/steps").and_then(Value::as_array_mut) else {
        return Ok(BTreeSet::new());
    };
    let writes = if parallel {
        workflow_write_counts(steps, repo)?
    } else {
        HashMap::new()
    };
    workflow_daemon_worktrees(steps, repo, &writes, backend)
}

fn workflow_write_counts(steps: &[Value], repo: &str) -> Result<HashMap<String, usize>, String> {
    let mut writes = HashMap::new();
    for step in steps.iter().filter(|step| !inspection(step["tool"].as_str().unwrap_or_default())) {
        let worktree = effective_repo(&step["arguments"], Some(repo))?;
        *writes.entry(worktree).or_insert(0) += 1;
    }
    Ok(writes)
}

fn workflow_daemon_worktrees(
    steps: &mut [Value],
    repo: &str,
    writes: &HashMap<String, usize>,
    backend: &Path,
) -> Result<BTreeSet<String>, String> {
    let mut worktrees = BTreeSet::new();
    for step in steps.iter_mut().filter(|step| step["tool"] == "test") {
        let args = &mut step["arguments"];
        let worktree = effective_repo(args, Some(repo))?;
        if configure_workflow_daemon(args, &worktree, writes.get(&worktree).copied().unwrap_or_default(), backend)? {
            worktrees.insert(worktree);
        }
    }
    Ok(worktrees)
}

fn configure_workflow_daemon(args: &mut Value, worktree: &str, writes: usize, backend: &Path) -> Result<bool, String> {
    if writes > 1 {
        if args["mvnd"] == true {
            return Err(format!("Parallel Maven Daemon test shares worktree {worktree} with another build. Use composite_run or separate worktrees."));
        }
        return Ok(false);
    }
    apply_daemon_preference(args, worktree, backend)?;
    if args["mvnd"] != true {
        return Ok(false);
    }
    args["repo"] = json!(worktree);
    Ok(true)
}

fn preferred_daemon(repo: &str, backend: &Path) -> bool {
    let Ok(install_root) = crate::install_root(backend) else {
        return false;
    };
    Command::new("bash")
        .args(["-c", r#"
            source "$1"
            base_path="$(makevn_detect_maven_base_path "$2")"
            [[ -n "$base_path" ]] || exit 1
            makevn_mvnd_status "$2" "$base_path"
            [[ "$MAKEVN_MVND_STATUS" == mvnd ]]
        "#, "makevn-mvnd-preference"])
        .arg(install_root.join("libexec/makevn/common.sh"))
        .arg(repo)
        .current_dir(repo)
        .output()
        .is_ok_and(|output| output.status.success())
}

fn read_requests(sender: mpsc::Sender<Event>) {
    thread::spawn(move || {
        for line in io::stdin().lock().lines() {
            let event = parse_input(line);
            if let Some(event) = event {
                if sender.send(event).is_err() {
                    return;
                }
            }
        }
        let _ = sender.send(Event::InputClosed);
    });
}

fn parse_input(line: io::Result<String>) -> Option<Event> {
    match line {
        Ok(line) if line.trim().is_empty() => None,
        Ok(line) => Some(match serde_json::from_str(&line) {
            Ok(request) => Event::Request(request),
            Err(error) => Event::InputFailed(format!("invalid JSON-RPC request: {error}")),
        }),
        Err(error) => Some(Event::InputFailed(format!("failed to read stdin: {error}"))),
    }
}

impl McpSession {
    fn serve(
        &mut self,
        receiver: mpsc::Receiver<Event>,
        interrupted: Arc<AtomicBool>,
    ) -> Result<i32, String> {
        let mut failure = None;
        loop {
            if interrupted.load(Ordering::SeqCst) {
                self.stop();
            }
            if self.stopping && self.active.is_empty() {
                break;
            }
            if let Ok(event) = receiver.recv_timeout(Duration::from_millis(50)) {
                if let Err(error) = self.event(event) {
                    failure.get_or_insert(error);
                    self.stop();
                }
            }
        }
        failure.map_or(Ok(0), Err)
    }

    fn event(&mut self, event: Event) -> Result<(), String> {
        match event {
            Event::Request(request) if !self.stopping => self.request(request),
            Event::Request(_) => Ok(()),
            Event::InputClosed => {
                self.stop();
                Ok(())
            }
            Event::InputFailed(error) => Err(error),
            Event::Start(execution_id) => self.start(&execution_id),
            Event::Completed {
                id,
                params,
                execution_id,
                result,
            } => self.completed(id, params, &execution_id, result),
        }
    }

    fn request(&mut self, request: Value) -> Result<(), String> {
        let id = request["id"].clone();
        let params = &request["params"];
        match request["method"].as_str().unwrap_or_default() {
            "initialize" => write_message(json!({"jsonrpc":"2.0", "id":id, "result": {
                "protocolVersion": mcp_server::negotiated_protocol(params), "capabilities":{"tools":{}},
                "serverInfo":{"name":"makevn", "version":env!("CARGO_PKG_VERSION")}
            }})),
            "notifications/cancelled" => {
                self.cancel_request(&params["requestId"]);
                Ok(())
            }
            "tools/list" => write_message(
                json!({"jsonrpc":"2.0", "id":id, "result":{"tools":mcp_server::tools_list()}}),
            ),
            "tools/call" => self.call(id, params.clone()),
            _ if id.is_null() => Ok(()),
            _ => write_message(
                json!({"jsonrpc":"2.0", "id":id, "error":{"code":-32601,"message":"unknown method"}}),
            ),
        }
    }

    fn call(&mut self, id: Value, params: Value) -> Result<(), String> {
        if params["name"] == "execution_cleanup" {
            let result = cleanup_control(&self.store, &params).unwrap_or_else(|error| {
                mcp_server::standard_tool_result(&ToolCallResult::failure(error), &params)
            });
            return write_message(json!({"jsonrpc":"2.0", "id":id, "result":result}));
        }
        if control_name(params["name"].as_str().unwrap_or_default()) {
            let result = self.control(&params).unwrap_or_else(|error| {
                mcp_server::standard_tool_result(&ToolCallResult::failure(error), &params)
            });
            return write_message(json!({"jsonrpc":"2.0", "id":id, "result":result}));
        }
        if let Err(error) = mcp_server::validate_call(&params) {
            return write_message(mcp_server::tool_validation_response(id, &params, error));
        }
        match self.launch(id.clone(), params.clone()) {
            Ok(()) => Ok(()),
            Err(error) => write_message(mcp_server::tool_failure_response(id, &params, error)),
        }
    }

    fn launch(&mut self, id: Value, mut params: Value) -> Result<(), String> {
        crate::execution_retention::automatic(&self.store);
        let (mut record, locks) = self.store.prepare(&params)?;
        let execution_id = record.execution_id.clone();
        let (mut child, ownership) = match self.spawn_execution(&record, &mut params, locks) {
            Ok(process) => process,
            Err(error) => {
                record.state = "failed".into();
                record.exit_code = Some(-1);
                save_record(&self.store.root, &record)?;
                return Err(error);
            }
        };
        self.active.insert(
            execution_id.clone(),
            ActiveExecution {
                request_id: id.clone(),
                ownership,
                suppress_response: false,
                cancellation_requested: false,
            },
        );
        self.sender
            .send(Event::Start(execution_id.clone()))
            .map_err(|error| error.to_string())?;
        let sender = self.sender.clone();
        thread::spawn(move || {
            let mut output = Vec::new();
            let read = child.stdout.take().unwrap().read_to_end(&mut output);
            let status = child.wait();
            let result = supervisor_result(read, status, &output);
            let _ = sender.send(Event::Completed {
                id,
                params,
                execution_id,
                result,
            });
        });
        Ok(())
    }

    fn spawn_execution(
        &mut self,
        record: &ExecutionRecord,
        params: &mut Value,
        locks: Vec<std::fs::File>,
    ) -> Result<(std::process::Child, ChildStdin), String> {
        let mut groups = HashMap::new();
        for repo in daemon_worktrees(params, &record.repo, &self.backend)? {
            let group = mcp_supervisor::DaemonGroup::for_worktree(
                &mut self.daemon_groups,
                &repo,
                &self.executable,
            )?;
            groups.insert(repo, group);
        }
        mcp_supervisor::spawn(
            &self.executable,
            &self.backend,
            self.store.root.clone(),
            record.clone(),
            params.clone(),
            locks,
            groups,
        )
    }

    fn start(&mut self, execution_id: &str) -> Result<(), String> {
        let Some(active) = self.active.get_mut(execution_id) else {
            return Ok(());
        };
        if !self.stopping && !active.cancellation_requested {
            active
                .ownership
                .write_all(b"S")
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }

    fn completed(
        &mut self,
        id: Value,
        params: Value,
        execution_id: &str,
        result: ToolCallResult,
    ) -> Result<(), String> {
        let active = self.active.remove(execution_id);
        let mut record = self.store.get(execution_id)?;
        if !record.terminal() {
            record.state = "failed".into();
            record.exit_code = Some(result.exit_code);
            save_record(&self.store.root, &record)?;
        }
        if self.stopping || active.is_some_and(|active| active.suppress_response) {
            return Ok(());
        }
        let mut result = mcp_server::standard_tool_result(&result, &params);
        suggest_execution_logs(&mut result, &record);
        add_identity(&mut result, &record);
        write_message(json!({"jsonrpc":"2.0", "id":id, "result":result}))
    }

    fn control(&mut self, params: &Value) -> Result<Value, String> {
        let args = &params["arguments"];
        validate_control_arguments(params)?;
        let mut result = mcp_server::standard_tool_result(
            &ToolCallResult {
                output: String::new(),
                exit_code: 0,
                duration_ms: 0,
                doctor_snapshot: None,
                next_suggestion: None,
            },
            params,
        );
        if params["name"] == "execution_list" {
            result["structuredContent"]["executions"] =
                serde_json::to_value(self.store.list(args)?).map_err(|error| error.to_string())?;
        } else {
            let record = self.control_record(params)?;
            add_identity(&mut result, &record);
            self.attach_execution_logs(&mut result, &record, params)?;
            result["structuredContent"]["execution"] =
                serde_json::to_value(record).map_err(|error| error.to_string())?;
        }
        mirror_content(&mut result);
        Ok(result)
    }

    fn attach_execution_logs(
        &self,
        result: &mut Value,
        record: &ExecutionRecord,
        params: &Value,
    ) -> Result<(), String> {
        if params["name"] == "execution_logs" {
            result["structuredContent"]["untrustedData"]["executionLogs"] =
                crate::execution_logs::read(&self.store, record, &params["arguments"])?;
        }
        Ok(())
    }

    fn control_record(&mut self, params: &Value) -> Result<ExecutionRecord, String> {
        let id = params["arguments"]["executionId"]
            .as_str()
            .ok_or("executionId is required")?;
        let resolved;
        let id = if params["name"] == "execution_logs" {
            resolved = crate::execution_logs::resolve_id(&self.store, id)?;
            resolved.as_str()
        } else {
            id
        };
        let mut record = self.store.get(id)?.snapshot();
        if params["name"] == "execution_cancel" {
            self.cancel_execution(&mut record)?;
        }
        Ok(record)
    }

    fn cancel_execution(&mut self, record: &mut ExecutionRecord) -> Result<(), String> {
        if record.session_id != self.store.session_id {
            return Err(format!("Execution {} belongs to session {}; cancellation is restricted to the owning session", record.execution_id, record.session_id));
        }
        if record.terminal() {
            return Ok(());
        }
        let active = self
            .active
            .get_mut(&record.execution_id)
            .ok_or("execution is no longer owned by this session")?;
        request_cancel(active);
        record.state = "cancelling".into();
        Ok(())
    }

    fn cancel_request(&mut self, id: &Value) {
        if id.is_null() {
            return;
        }
        for active in self
            .active
            .values_mut()
            .filter(|active| &active.request_id == id)
        {
            active.suppress_response = true;
            request_cancel(active);
        }
    }

    fn stop(&mut self) {
        if self.stopping {
            return;
        }
        self.stopping = true;
        for active in self.active.values_mut() {
            request_cancel(active);
        }
    }
}

fn request_cancel(active: &mut ActiveExecution) {
    if !active.cancellation_requested {
        active.cancellation_requested = true;
        let _ = active.ownership.write_all(b"C");
    }
}

fn supervisor_result(
    read: io::Result<usize>,
    status: io::Result<std::process::ExitStatus>,
    output: &[u8],
) -> ToolCallResult {
    let result = read
        .and(status)
        .map_err(|error| error.to_string())
        .and_then(|status| {
            if status.success() {
                Ok(())
            } else {
                Err(format!("execution supervisor exited with {status}"))
            }
        })
        .and_then(|()| {
            serde_json::from_slice(output)
                .map_err(|error| format!("invalid supervisor result: {error}"))
        });
    result.unwrap_or_else(ToolCallResult::failure)
}

fn add_identity(result: &mut Value, record: &ExecutionRecord) {
    result["structuredContent"]["executionId"] = json!(record.execution_id);
    result["structuredContent"]["executionState"] = json!(record.state);
    if record.state == "cancelled" && result["structuredContent"]["tool"] == record.command {
        result["structuredContent"]["message"] =
            json!("MakeVN execution cancelled; logs preserved.");
        result["structuredContent"]["nextSuggestion"] =
            json!(format!("Execution cancelled; inspect its preserved logs before retrying. {}",
                result["structuredContent"]["nextSuggestion"].as_str().unwrap_or_default()));
    }
    let logs = result["structuredContent"]["logPaths"]
        .as_array_mut()
        .unwrap();
    for path in &record.log_paths {
        let path = json!(path);
        if !logs.contains(&path) {
            logs.push(path);
        }
    }
    mirror_content(result);
}

fn suggest_execution_logs(result: &mut Value, record: &ExecutionRecord) {
    if record.state != "failed" {
        return;
    }
    let args = json!({"executionId": record.execution_id});
    let next = &mut result["structuredContent"]["nextSuggestion"];
    let existing = next.as_str().unwrap_or_default();
    *next = json!(format!("{existing} Inspect captured logs with MCP execution_logs {args} or CLI makevn execution-logs {}.", record.execution_id));
}

fn mirror_content(result: &mut Value) {
    result["content"][0]["text"] = json!(result["structuredContent"].to_string());
}

fn write_message(message: Value) -> Result<(), String> {
    let mut stdout = io::stdout().lock();
    writeln!(stdout, "{message}")
        .and_then(|()| stdout.flush())
        .map_err(|error| error.to_string())
}

fn cleanup_control(store: &ExecutionStore, params: &Value) -> Result<Value, String> {
    validate_control_arguments(params)?;
    let mut result = mcp_server::standard_tool_result(
        &ToolCallResult {
            output: String::new(),
            exit_code: 0,
            duration_ms: 0,
            doctor_snapshot: None,
            next_suggestion: None,
        },
        params,
    );
    result["structuredContent"]["cleanup"] =
        crate::execution_retention::cleanup(store, &params["arguments"])?;
    mirror_content(&mut result);
    Ok(result)
}

fn control_name(name: &str) -> bool {
    matches!(
        name,
        "execution_list" | "execution_status" | "execution_cancel" | "execution_logs"
    )
}

fn validate_control_arguments(params: &Value) -> Result<(), String> {
    let name = params["name"].as_str().unwrap_or_default();
    let schema = control_tool(name, "")["inputSchema"].clone();
    let empty = serde_json::Map::new();
    let args = match params.get("arguments") {
        None => &empty,
        Some(value) => value.as_object().ok_or("arguments must be an object")?,
    };
    for (key, value) in args {
        let ty = schema["properties"][key]["type"]
            .as_str()
            .ok_or_else(|| format!("unknown argument '{key}'"))?;
        if !mcp_server::option_value_matches(ty, value) {
            return Err(format!("argument '{key}' must be {ty}"));
        }
    }
    Ok(())
}

pub fn control_tools() -> Vec<Value> {
    [("execution_cleanup", "Remove terminal executions and their private logs older than retentionDays (default MAKEVN_RETENTION_DAYS or 3). dryRun previews candidates without deleting."),
     ("execution_list", "List active MakeVN executions across local MCP sessions. includeFinished also returns preserved terminal executions."),
     ("execution_status", "Inspect one execution, including its owning session, repository, PR, state and logs. Pass the 32-character hexadecimal executionId from a MakeVN result or execution_list."),
     ("execution_logs", "Read captured stdout, stderr and supervisor logs for a recorded MakeVN execution without rerunning it. Supply executionId and optionally a zero-based step, tail and case-sensitive literal contains filter. Read structuredContent.untrustedData.executionLogs."),
     ("execution_cancel", "Cancel only an execution owned by this MCP session. Idempotent for stopped executions; cleanup uses five seconds of grace and two seconds of confirmation.")]
        .into_iter().map(|(name, description)| control_tool(name, description)).collect()
}

fn control_tool(name: &str, description: &str) -> Value {
    let mut output = mcp_server::result_schema();
    let input = if name == "execution_logs" {
        output["properties"]["execution"] = crate::mcp_execution::record_schema();
        output["properties"]["untrustedData"]["properties"]["executionLogs"] = crate::execution_logs::schema();
        crate::execution_logs::input_schema()
    } else if name == "execution_cleanup" {
        output["properties"]["cleanup"] = crate::execution_retention::schema();
        json!({"type":"object", "properties":{"retentionDays":{"type":"integer","minimum":1}, "dryRun":{"type":"boolean","default":false}}, "additionalProperties":false})
    } else if name == "execution_list" {
        output["properties"]["executions"] =
            json!({"type":"array", "items":crate::mcp_execution::record_schema()});
        json!({"type":"object", "properties":{"repo":{"type":"string"}, "includeFinished":{"type":"boolean","default":false}}, "additionalProperties":false})
    } else {
        output["properties"]["execution"] = crate::mcp_execution::record_schema();
        json!({"type":"object", "required":["executionId"], "properties":{"executionId":{"type":"string"}}, "additionalProperties":false})
    };
    json!({"name":name,"description":description,"inputSchema":input,"outputSchema":output})
}

#[cfg(test)]
#[path = "mcp_runtime_test.rs"]
mod tests;
