use std::io::{self, BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::os::unix::process::CommandExt;

use serde_json::{json, Map, Value};

pub fn run_mcp_server(current_exe: PathBuf) -> Result<i32, String> {
    let makevn_bin = resolve_makevn_bin(&current_exe)?;
    let stdin = io::stdin();
    let mut stdout = io::stdout();

    for line in stdin.lock().lines() {
        let line = line.map_err(|e| format!("failed to read stdin: {e}"))?;
        let line = line.trim().to_owned();
        if line.is_empty() {
            continue;
        }

        let request: Value =
            serde_json::from_str(&line).map_err(|e| format!("invalid JSON-RPC request: {e}"))?;

        let method = request["method"].as_str().unwrap_or("").to_owned();
        let id = request["id"].clone();
        let params = request["params"].clone();

        if method == "initialize" {
            write_response(
                &mut stdout,
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": { "tools": {} },
                        "serverInfo": {
                            "name": "makevn",
                            "version": env!("CARGO_PKG_VERSION")
                        }
                    }
                }),
            )?;
            continue;
        }

        if method == "notifications/initialized" {
            continue;
        }

        if method == "tools/list" {
            write_response(
                &mut stdout,
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": { "tools": tools_list() }
                }),
            )?;
            continue;
        }

        if method == "tools/call" {
            let result = handle_tool_call(&makevn_bin, &params);
            let response = match result {
                Ok(tool_result) => {
                    let mut content = vec![json!({"type": "text", "text": tool_result.output})];
                    if tool_result.exit_code != 0 || tool_result.duration_ms > 0 {
                        let tool_name = params["name"].as_str().unwrap_or("unknown");
                        content.push(json!({
                            "type": "text",
                            "text": json!({
                                "exitCode": tool_result.exit_code,
                                "durationMs": tool_result.duration_ms,
                                "tool": tool_name,
                            }).to_string()
                        }));
                    }
                    json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": { "content": content }
                    })
                }
                Err(err) => json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": { "code": -32603, "message": err }
                }),
            };
            write_response(&mut stdout, response)?;
            continue;
        }

        write_response(
            &mut stdout,
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32601, "message": format!("unknown method: {method}") }
            }),
        )?;
    }

    Ok(0)
}

fn write_response(stdout: &mut io::Stdout, response: Value) -> Result<(), String> {
    writeln!(stdout, "{}", serde_json::to_string(&response).unwrap())
        .map_err(|e| format!("write error: {e}"))?;
    stdout.flush().map_err(|e| format!("flush error: {e}"))
}

fn resolve_makevn_bin(current_exe: &Path) -> Result<PathBuf, String> {
    let bin_dir = current_exe.parent().ok_or_else(|| {
        format!(
            "failed to resolve executable directory: {}",
            current_exe.display()
        )
    })?;
    let sibling = bin_dir.join("makevn");
    if sibling.is_file() {
        return Ok(sibling);
    }
    if current_exe
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name == "makevn")
    {
        return Ok(current_exe.to_path_buf());
    }
    Err(format!(
        "makevn sibling binary not found at {}",
        sibling.display()
    ))
}

#[derive(Clone, Copy)]
struct ToolSpec {
    name: &'static str,
    description: &'static str,
    command: &'static [&'static str],
    options: &'static [ToolOption],
}

#[derive(Clone, Copy)]
struct ToolOption {
    name: &'static str,
    ty: &'static str,
    description: &'static str,
    required: bool,
}

const COMMON_REPO: ToolOption = ToolOption {
    name: "repo",
    ty: "string",
    description: "Path to the repository",
    required: false,
};
const COMPACT: ToolOption = ToolOption {
    name: "compact",
    ty: "boolean",
    description: "Use compact output",
    required: false,
};
const VERBOSE: ToolOption = ToolOption {
    name: "verbose",
    ty: "boolean",
    description: "Verbose output",
    required: false,
};
const MODULE: ToolOption = ToolOption {
    name: "module",
    ty: "string",
    description: "Specific Maven module",
    required: false,
};
const DRY_RUN: ToolOption = ToolOption {
    name: "dry-run",
    ty: "boolean",
    description: "Show what would be done",
    required: false,
};
const CLEAN_GENERATED_CONTRACT_TARGETS: ToolOption = ToolOption {
    name: "clean-generated-contract-targets",
    ty: "boolean",
    description: "Clean stale generated sources from code-generation plugins (Avro, OpenAPI, Protobuf, etc.)",
    required: false,
};
const EXEC_TIMEOUT_SECONDS: ToolOption = ToolOption {
    name: "timeout-seconds",
    ty: "number",
    description: "Maximum seconds to wait for exec commands, default 120, range 1-900",
    required: false,
};

const EXEC_DEFAULT_TIMEOUT_SECONDS: u64 = 120;
const EXEC_MAX_TIMEOUT_SECONDS: u64 = 900;

const TOOL_SPECS: &[ToolSpec] = &[
    ToolSpec { name: "doctor", description: "Inspect a Java/Maven repository. Run this first to understand the repo setup.", command: &["doctor"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "init", description: "Initialize makevn in a repository. Creates .makevn/ configuration directory.", command: &["init"], options: &[COMMON_REPO, DRY_RUN, ToolOption { name: "force", ty: "boolean", description: "Force reinitialization", required: false }, COMPACT] },
    ToolSpec { name: "make_install", description: "Install optional Makefile integration.", command: &["make", "install"], options: &[COMMON_REPO, DRY_RUN, COMPACT] },
    ToolSpec { name: "make_uninstall", description: "Remove optional Makefile integration.", command: &["make", "uninstall"], options: &[COMMON_REPO, DRY_RUN, COMPACT] },
    ToolSpec { name: "uninstall", description: "Remove makevn local repository state.", command: &["uninstall"], options: &[COMMON_REPO, DRY_RUN, COMPACT] },
    ToolSpec { name: "profile_refresh", description: "Refresh makevn repository profile detection.", command: &["profile", "refresh"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "compile", description: "Compile the Maven project source code.", command: &["compile"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "test_compile", description: "Compile Maven tests.", command: &["test-compile"], options: &[COMMON_REPO] },
    ToolSpec { name: "compile_tests", description: "Compile Maven tests.", command: &["compile-tests"], options: &[COMMON_REPO] },
    ToolSpec { name: "validate", description: "Validate the Maven project model.", command: &["validate"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "package", description: "Compile and package without running tests.", command: &["package"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "build", description: "Full Maven build (compile, test, package).", command: &["build"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "clean", description: "Clean Maven build output.", command: &["clean"], options: &[COMMON_REPO, CLEAN_GENERATED_CONTRACT_TARGETS, COMPACT] },
    ToolSpec { name: "test", description: "Run tests with optional name filter. Use fast=true only after a successful compile or test run when sources have not changed.", command: &["test"], options: &[COMMON_REPO, ToolOption { name: "name", ty: "string", description: "Test class name or comma-separated names", required: false }, ToolOption { name: "fast", ty: "boolean", description: "Skip compilation only after a successful compile or test run when sources have not changed. Do not use on the first test run.", required: false }, COMPACT] },
    ToolSpec { name: "verify_ut", description: "Run unit-test-only verification.", command: &["verify-ut"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "verify_ut_coverage", description: "Run unit-test-only verification with coverage.", command: &["verify-ut-coverage"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "verify_it", description: "Run integration-test-only verification.", command: &["verify-it"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "verify_it_coverage", description: "Run integration-test-only verification with coverage.", command: &["verify-it-coverage"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "verify", description: "Run full combined verification (unit tests + integration tests).", command: &["verify"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "verify_changes_preview", description: "Preview the changed production modules or tests without running Maven.", command: &["verify-changes-preview"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "verify_changes", description: "Verify only the changed production modules or tests.", command: &["verify-changes"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "coverage", description: "Check the latest JaCoCo aggregate coverage report.", command: &["coverage"], options: &[COMMON_REPO, ToolOption { name: "threshold", ty: "number", description: "Coverage threshold percentage", required: false }, COMPACT] },
    ToolSpec { name: "coverage_changes", description: "Check incremental and per-module coverage.", command: &["coverage-changes"], options: &[COMMON_REPO, ToolOption { name: "threshold", ty: "number", description: "Per-module coverage threshold", required: false }, ToolOption { name: "overall-threshold", ty: "number", description: "Overall coverage threshold", required: false }, VERBOSE, COMPACT] },
    ToolSpec { name: "pr_verify", description: "Run a local PR-style verification flow.", command: &["pr-verify"], options: &[COMMON_REPO, COMPACT] },
    ToolSpec { name: "format", description: "Check or apply code formatting.", command: &["format"], options: &[COMMON_REPO, ToolOption { name: "apply", ty: "boolean", description: "Apply formatting changes", required: false }, COMPACT] },
    ToolSpec { name: "checkstyle", description: "Run Checkstyle code style checks.", command: &["checkstyle"], options: &[COMMON_REPO, MODULE, VERBOSE, COMPACT] },
    ToolSpec { name: "docker_up", description: "Start all boot compose services.", command: &["docker-up"], options: &[COMMON_REPO] },
    ToolSpec { name: "docker_down", description: "Stop all boot compose services.", command: &["docker-down"], options: &[COMMON_REPO] },
    ToolSpec { name: "docker_ps", description: "List running Docker containers for the compose setup.", command: &["docker-ps"], options: &[COMMON_REPO] },
    ToolSpec { name: "docker_stats", description: "Show one-shot CPU and memory stats for all running Docker containers.", command: &["docker-stats"], options: &[COMMON_REPO] },
    ToolSpec { name: "docker_ps_required", description: "Validate required Docker services are running and healthy.", command: &["docker-ps-required"], options: &[COMMON_REPO, ToolOption { name: "compose", ty: "string", description: "Compose profile: boot or karate", required: false }, ToolOption { name: "wait-seconds", ty: "number", description: "Seconds to wait for required services", required: false }] },
    ToolSpec { name: "karate_docker_up", description: "Start all Karate E2E compose services.", command: &["karate-docker-up"], options: &[COMMON_REPO] },
    ToolSpec { name: "karate_docker_down", description: "Stop all Karate E2E compose services.", command: &["karate-docker-down"], options: &[COMMON_REPO] },
    ToolSpec { name: "karate_test", description: "Run Karate tests.", command: &["karate-test"], options: &[COMMON_REPO, ToolOption { name: "tag", ty: "string", description: "Karate tag filter", required: false }] },
    ToolSpec { name: "karate_all", description: "Run the full Karate application and test lifecycle.", command: &["karate-all"], options: &[COMMON_REPO, ToolOption { name: "tag", ty: "string", description: "Karate tag filter", required: false }] },
    ToolSpec { name: "run_app", description: "Run the detected application in the foreground.", command: &["run-app"], options: &[COMMON_REPO] },
    ToolSpec { name: "run_app_bg", description: "Run the detected application in the background.", command: &["run-app-bg"], options: &[COMMON_REPO] },
    ToolSpec { name: "stop_app", description: "Stop the background application started by makevn.", command: &["stop-app"], options: &[COMMON_REPO] },
    ToolSpec { name: "run", description: "Run the detected application using repository defaults.", command: &["run"], options: &[COMMON_REPO] },
    ToolSpec { name: "exec", description: "Run a bounded arbitrary command with makevn's resolved repository environment. Prefer typed makevn tools for supported Maven, Docker, and JDK workflows; use native agent shell/git tools for git operations. Do not use for interactive commands.", command: &["exec"], options: &[COMMON_REPO, ToolOption { name: "command", ty: "string", description: "The command to execute, e.g. 'mvn -v'", required: true }, ToolOption { name: "context", ty: "string", description: "Execution context: 'code' or 'karate'", required: false }, EXEC_TIMEOUT_SECONDS, COMPACT] },
    ToolSpec { name: "jdk_current", description: "Show the currently resolved JDK version.", command: &["jdk", "current"], options: &[COMMON_REPO] },
    ToolSpec { name: "jdk_list", description: "List discovered JDK installations.", command: &["jdk", "list"], options: &[COMMON_REPO] },
    ToolSpec { name: "mutation", description: "Run PIT mutation testing. Detects pitest-maven plugin automatically. WARNING: Very slow (30+ min for large projects).", command: &["mutation"], options: &[COMMON_REPO, MODULE, VERBOSE, COMPACT] },
    ToolSpec { name: "composite_run", description: "Execute a sequence of makevn commands with step-by-step progress. Each step is a tool call with optional args. Returns JSON with per-step results. Use fail-fast to stop on first error.", command: &[], options: &[COMMON_REPO, ToolOption { name: "steps", ty: "array", description: "JSON array of command steps. Each step: {\"tool\":\"verify_ut\",\"args\":{\"compact\":true}}", required: true }, ToolOption { name: "fail-fast", ty: "boolean", description: "Stop on first non-zero step (default: true)", required: false }] },
    ToolSpec { name: "parallel_run", description: "Execute independent makevn commands in parallel. Each step runs in a separate thread. Returns JSON with per-step results. Use for independent operations like parallel UT+IT.", command: &[], options: &[COMMON_REPO, ToolOption { name: "steps", ty: "array", description: "JSON array of command steps. Each step: {\"tool\":\"verify_ut\",\"args\":{\"compact\":true}}", required: true }] },
];

fn tools_list() -> Vec<Value> {
    TOOL_SPECS.iter().map(tool).collect()
}

fn tool(spec: &ToolSpec) -> Value {
    let mut properties = Map::new();
    let mut required = Vec::new();

    for option in spec.options {
        properties.insert(
            option.name.into(),
            json!({
                "type": option.ty,
                "description": option.description,
            }),
        );
        if option.required {
            required.push(option.name);
        }
    }

    let mut schema = json!({
        "type": "object",
        "properties": properties,
    });
    if !required.is_empty() {
        schema["required"] = json!(required);
    }

    json!({
        "name": spec.name,
        "description": spec.description,
        "inputSchema": schema,
    })
}

struct ToolCallResult {
    output: String,
    exit_code: i32,
    duration_ms: u128,
}

fn handle_tool_call(makevn_bin: &Path, params: &Value) -> Result<ToolCallResult, String> {
    let tool_name = params["name"]
        .as_str()
        .ok_or_else(|| String::from("missing tool name"))?;
    let args = params["arguments"].as_object().cloned().unwrap_or_default();

    if tool_name == "composite_run" {
        let output = handle_composite_run(makevn_bin, &args)?;
        return Ok(ToolCallResult {
            output,
            exit_code: 0,
            duration_ms: 0,
        });
    }
    if tool_name == "parallel_run" {
        let output = handle_parallel_run(makevn_bin, &args)?;
        return Ok(ToolCallResult {
            output,
            exit_code: 0,
            duration_ms: 0,
        });
    }

    let spec = TOOL_SPECS
        .iter()
        .find(|spec| spec.name == tool_name)
        .ok_or_else(|| format!("unknown makevn tool: {tool_name}"))?;

    let mut cmd_args: Vec<String> = Vec::new();
    if let Some(repo) = args
        .get("repo")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
    {
        cmd_args.push("--repo".into());
        cmd_args.push(repo.into());
    }
    cmd_args.push("--compact".into());
    cmd_args.extend(spec.command.iter().map(|part| (*part).to_owned()));
    push_tool_flags(&mut cmd_args, spec, &args)?;

    let start = Instant::now();
    let output = if tool_name == "exec" {
        run_makevn_with_timeout(makevn_bin, &cmd_args, exec_timeout_seconds(&args)?)?
    } else {
        Command::new(makevn_bin)
            .args(&cmd_args)
            .env("NO_COLOR", "1")
            .env("MAKEVN_COMPACT_OUTPUT", "1")
            .env("MAKEVN_AGENT_OUTPUT", "1")
            .env("CI", "1")
            .output()
            .map_err(|e| format!("failed to execute makevn: {e}"))?
            .into()
    };
    let duration_ms = start.elapsed().as_millis();

    let mut result = String::new();
    if !output.stdout.is_empty() {
        result.push_str(String::from_utf8_lossy(&output.stdout).trim());
    }
    if !output.stderr.is_empty() {
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(String::from_utf8_lossy(&output.stderr).trim());
    }
    if output.timed_out {
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(&format!("timed out after {}s", output.timeout_seconds));
    } else if !output.status.success() {
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(&format!("exit code {}", output.status.code().unwrap_or(-1)));
    }

    let exit_code = if output.timed_out {
        -1
    } else {
        output.status.code().unwrap_or(-1)
    };

    Ok(ToolCallResult {
        output: result,
        exit_code,
        duration_ms,
    })
}

fn parse_steps(args: &Map<String, Value>) -> Result<Vec<Value>, String> {
    let Some(steps_value) = args.get("steps") else {
        return Err(String::from("missing required argument: steps"));
    };
    let Some(steps_array) = steps_value.as_array() else {
        return Err(String::from("steps must be a JSON array"));
    };
    if steps_array.is_empty() {
        return Err(String::from("steps must not be empty"));
    }
    Ok(steps_array.clone())
}

fn execute_single_step(
    makevn_bin: &Path,
    step: &Value,
    global_repo: Option<&str>,
) -> Result<(String, i32, u128), String> {
    let step_tool = step["tool"]
        .as_str()
        .ok_or_else(|| String::from("each step must have a 'tool' field"))?;
    let step_args = step["arguments"].as_object().cloned().unwrap_or_default();

    let spec = TOOL_SPECS
        .iter()
        .find(|spec| spec.name == step_tool)
        .ok_or_else(|| format!("unknown makevn tool in step: {step_tool}"))?;

    let mut cmd_args: Vec<String> = Vec::new();
    let repo = step_args
        .get("repo")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .or(global_repo);
    if let Some(repo) = repo {
        cmd_args.push("--repo".into());
        cmd_args.push(repo.into());
    }
    cmd_args.push("--compact".into());
    cmd_args.extend(spec.command.iter().map(|part| (*part).to_owned()));
    push_tool_flags(&mut cmd_args, spec, &step_args)?;

    let start = Instant::now();
    let output = if step_tool == "exec" {
        run_makevn_with_timeout(makevn_bin, &cmd_args, exec_timeout_seconds(&step_args)?)?
    } else {
        Command::new(makevn_bin)
            .args(&cmd_args)
            .env("NO_COLOR", "1")
            .env("MAKEVN_COMPACT_OUTPUT", "1")
            .env("MAKEVN_AGENT_OUTPUT", "1")
            .env("CI", "1")
            .output()
            .map_err(|e| format!("failed to execute makevn: {e}"))?
            .into()
    };
    let duration_ms = start.elapsed().as_millis();

    let mut result = String::new();
    if !output.stdout.is_empty() {
        result.push_str(String::from_utf8_lossy(&output.stdout).trim());
    }
    if !output.stderr.is_empty() {
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(String::from_utf8_lossy(&output.stderr).trim());
    }
    if output.timed_out {
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(&format!("timed out after {}s", output.timeout_seconds));
    }

    let exit_code = if output.timed_out {
        -1
    } else {
        output.status.code().unwrap_or(-1)
    };

    Ok((result, exit_code, duration_ms))
}

fn handle_composite_run(makevn_bin: &Path, args: &Map<String, Value>) -> Result<String, String> {
    let steps = parse_steps(args)?;
    let fail_fast = args
        .get("fail-fast")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);
    let global_repo = args
        .get("repo")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty());

    let mut results = Vec::new();
    let mut overall_exit_code = 0;

    for (i, step) in steps.iter().enumerate() {
        let step_tool = step["tool"]
            .as_str()
            .ok_or_else(|| String::from("each step must have a 'tool' field"))?;

        match execute_single_step(makevn_bin, step, global_repo) {
            Ok((output, exit_code, duration_ms)) => {
                let step_result = json!({
                    "step": i,
                    "tool": step_tool,
                    "exitCode": exit_code,
                    "durationMs": duration_ms,
                    "output": output,
                });
                results.push(step_result);

                if exit_code != 0 {
                    overall_exit_code = exit_code;
                    if fail_fast {
                        break;
                    }
                }
            }
            Err(err) => {
                let step_result = json!({
                    "step": i,
                    "tool": step_tool,
                    "exitCode": -1,
                    "durationMs": 0,
                    "output": err,
                });
                results.push(step_result);
                overall_exit_code = -1;
                if fail_fast {
                    break;
                }
            }
        }
    }

    let summary = json!({
        "steps": results,
        "total_steps": steps.len(),
        "executed_steps": results.len(),
        "failed": overall_exit_code != 0,
        "exitCode": overall_exit_code,
    });

    Ok(serde_json::to_string_pretty(&summary).unwrap())
}

fn handle_parallel_run(makevn_bin: &Path, args: &Map<String, Value>) -> Result<String, String> {
    let steps = parse_steps(args)?;
    let global_repo = args
        .get("repo")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_owned());

    let bin = makevn_bin.to_path_buf();
    let mut handles = Vec::new();

    for (i, step) in steps.iter().enumerate() {
        let step = step.clone();
        let bin = bin.clone();
        let repo = global_repo.clone();
        handles.push(thread::spawn(move || {
            let step_tool = step["tool"].as_str().unwrap_or("unknown");
            match execute_single_step(&bin, &step, repo.as_deref()) {
                Ok((output, exit_code, duration_ms)) => {
                    json!({
                        "step": i,
                        "tool": step_tool,
                        "exitCode": exit_code,
                        "durationMs": duration_ms,
                        "output": output,
                    })
                }
                Err(err) => {
                    json!({
                        "step": i,
                        "tool": step_tool,
                        "exitCode": -1,
                        "durationMs": 0,
                        "output": err,
                    })
                }
            }
        }));
    }

    let mut results = Vec::new();
    let mut overall_exit_code = 0;
    for handle in handles {
        let result = handle
            .join()
            .map_err(|_| String::from("thread panicked"))?;
        if let Some(exit_code) = result["exitCode"].as_i64() {
            if exit_code != 0 {
                overall_exit_code = exit_code as i32;
            }
        }
        results.push(result);
    }

    let summary = json!({
        "steps": results,
        "total_steps": steps.len(),
        "failed": overall_exit_code != 0,
        "exitCode": overall_exit_code,
    });

    Ok(serde_json::to_string_pretty(&summary).unwrap())
}

struct ToolOutput {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    status: std::process::ExitStatus,
    timed_out: bool,
    timeout_seconds: u64,
}

impl From<std::process::Output> for ToolOutput {
    fn from(output: std::process::Output) -> Self {
        Self {
            stdout: output.stdout,
            stderr: output.stderr,
            status: output.status,
            timed_out: false,
            timeout_seconds: 0,
        }
    }
}

fn exec_timeout_seconds(args: &Map<String, Value>) -> Result<u64, String> {
    let Some(value) = args.get("timeout-seconds") else {
        return Ok(EXEC_DEFAULT_TIMEOUT_SECONDS);
    };
    let Some(number) = value.as_u64() else {
        return Err(String::from("timeout-seconds must be an integer number"));
    };
    if !(1..=EXEC_MAX_TIMEOUT_SECONDS).contains(&number) {
        return Err(format!(
            "timeout-seconds must be between 1 and {EXEC_MAX_TIMEOUT_SECONDS}"
        ));
    }
    Ok(number)
}

fn run_makevn_with_timeout(
    makevn_bin: &Path,
    cmd_args: &[String],
    timeout_seconds: u64,
) -> Result<ToolOutput, String> {
    let mut command = Command::new(makevn_bin);
    command
        .args(cmd_args)
        .env("NO_COLOR", "1")
        .env("MAKEVN_COMPACT_OUTPUT", "1")
        .env("MAKEVN_AGENT_OUTPUT", "1")
        .env("CI", "1")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    command.process_group(0);

    let mut child = command
        .spawn()
        .map_err(|e| format!("failed to execute makevn: {e}"))?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| String::from("failed to capture makevn stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| String::from("failed to capture makevn stderr"))?;
    let stdout_reader = thread::spawn(move || read_all(stdout));
    let stderr_reader = thread::spawn(move || read_all(stderr));
    let deadline = Instant::now() + Duration::from_secs(timeout_seconds);

    let (status, timed_out) = loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|e| format!("failed to wait for makevn: {e}"))?
        {
            break (status, false);
        }
        if Instant::now() >= deadline {
            kill_makevn_child(&mut child);
            let status = child
                .wait()
                .map_err(|e| format!("failed to wait for timed out makevn: {e}"))?;
            break (status, true);
        }
        thread::sleep(Duration::from_millis(50));
    };

    let stdout = stdout_reader
        .join()
        .map_err(|_| String::from("failed to join stdout reader"))??;
    let stderr = stderr_reader
        .join()
        .map_err(|_| String::from("failed to join stderr reader"))??;

    Ok(ToolOutput {
        stdout,
        stderr,
        status,
        timed_out,
        timeout_seconds,
    })
}

#[cfg(unix)]
fn kill_makevn_child(child: &mut std::process::Child) {
    let pid = child.id() as i32;
    unsafe {
        libc::killpg(pid, libc::SIGKILL);
    }
}

#[cfg(not(unix))]
fn kill_makevn_child(child: &mut std::process::Child) {
    let _ = child.kill();
}

fn read_all(mut reader: impl Read) -> Result<Vec<u8>, String> {
    let mut buffer = Vec::new();
    reader
        .read_to_end(&mut buffer)
        .map_err(|e| format!("failed to read makevn output: {e}"))?;
    Ok(buffer)
}

fn push_tool_flags(
    cmd_args: &mut Vec<String>,
    spec: &ToolSpec,
    args: &Map<String, Value>,
) -> Result<(), String> {
    for option in spec.options {
        if matches!(option.name, "repo" | "compact") {
            continue;
        }
        let Some(value) = args.get(option.name) else {
            if option.required {
                return Err(format!("missing required argument: {}", option.name));
            }
            continue;
        };

        match option.name {
            "command" => {
                value
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| String::from("command must be a non-empty string"))?;
                continue;
            }
            "apply" | "clean-generated-contract-targets" | "dry-run" | "fast" | "force" | "verbose" => {
                if value.as_bool().unwrap_or(false) {
                    cmd_args.push(format!("--{}", option.name));
                }
            }
            "threshold" | "overall-threshold" | "wait-seconds" => {
                if let Some(number) = value.as_f64() {
                    cmd_args.push(format!("--{}", option.name));
                    cmd_args.push(format_number(number));
                }
            }
            "timeout-seconds" => {
                exec_timeout_seconds(args)?;
            }
            "compose" | "context" | "module" | "name" | "tag" => {
                if let Some(text) = value.as_str().filter(|s| !s.is_empty()) {
                    cmd_args.push(format!("--{}", option.name));
                    cmd_args.push(text.into());
                }
            }
            _ => {}
        }
    }
    if let Some(command) = args
        .get("command")
        .and_then(|value| value.as_str())
        .filter(|s| !s.is_empty())
    {
        cmd_args.push("--".into());
        cmd_args.extend(command.split_whitespace().map(str::to_owned));
    }
    Ok(())
}

fn format_number(number: f64) -> String {
    if number.fract() == 0.0 {
        format!("{number:.0}")
    } else {
        format!("{number}")
    }
}

#[cfg(test)]
mod tests {
    use super::{exec_timeout_seconds, push_tool_flags, TOOL_SPECS};
    use serde_json::{json, Map};

    #[test]
    fn exec_command_is_forwarded_after_tool_options() {
        let spec = TOOL_SPECS.iter().find(|spec| spec.name == "exec").unwrap();
        let mut args = Map::new();
        args.insert("context".into(), json!("code"));
        args.insert("command".into(), json!("mvn -v"));
        args.insert("timeout-seconds".into(), json!(5));
        let mut cmd_args = vec![String::from("exec")];

        push_tool_flags(&mut cmd_args, spec, &args).unwrap();

        assert_eq!(
            cmd_args,
            vec!["exec", "--context", "code", "--", "mvn", "-v"]
        );
    }

    #[test]
    fn exec_timeout_defaults_when_omitted() {
        let args = Map::new();

        assert_eq!(exec_timeout_seconds(&args).unwrap(), 120);
    }

    #[test]
    fn exec_timeout_accepts_valid_range() {
        let mut args = Map::new();
        args.insert("timeout-seconds".into(), json!(900));

        assert_eq!(exec_timeout_seconds(&args).unwrap(), 900);
    }

    #[test]
    fn exec_timeout_rejects_zero() {
        let mut args = Map::new();
        args.insert("timeout-seconds".into(), json!(0));

        assert!(exec_timeout_seconds(&args).is_err());
    }

    #[test]
    fn exec_timeout_rejects_above_maximum() {
        let mut args = Map::new();
        args.insert("timeout-seconds".into(), json!(901));

        assert!(exec_timeout_seconds(&args).is_err());
    }

    #[test]
    fn composite_run_tool_exists_in_specs() {
        let spec = TOOL_SPECS.iter().find(|s| s.name == "composite_run");
        assert!(spec.is_some(), "composite_run tool must be registered");
        let spec = spec.unwrap();
        assert!(spec.description.contains("sequence"));
        assert!(spec.options.iter().any(|o| o.name == "steps"));
        assert!(spec.options.iter().any(|o| o.name == "fail-fast"));
    }

    #[test]
    fn parallel_run_tool_exists_in_specs() {
        let spec = TOOL_SPECS.iter().find(|s| s.name == "parallel_run");
        assert!(spec.is_some(), "parallel_run tool must be registered");
        let spec = spec.unwrap();
        assert!(spec.description.contains("parallel"));
        assert!(spec.options.iter().any(|o| o.name == "steps"));
    }

    #[test]
    fn parse_steps_rejects_empty_array() {
        let mut args = Map::new();
        args.insert("steps".into(), json!([]));

        let result = super::parse_steps(&args);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("must not be empty"));
    }

    #[test]
    fn parse_steps_rejects_non_array() {
        let mut args = Map::new();
        args.insert("steps".into(), json!("not an array"));

        let result = super::parse_steps(&args);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("must be a JSON array"));
    }

    #[test]
    fn parse_steps_rejects_missing_steps() {
        let args = Map::new();

        let result = super::parse_steps(&args);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("missing required argument"));
    }

    #[test]
    fn parse_steps_accepts_valid_array() {
        let mut args = Map::new();
        args.insert(
            "steps".into(),
            json!([
                {"tool": "doctor"},
                {"tool": "test", "arguments": {"name": "MyTest"}}
            ]),
        );

        let result = super::parse_steps(&args);
        assert!(result.is_ok());
        assert_eq!(result.unwrap().len(), 2);
    }

    #[test]
    fn tool_schema_for_composite_run_has_array_type() {
        let spec = TOOL_SPECS.iter().find(|s| s.name == "composite_run").unwrap();
        let schema = super::tool(spec);
        let steps_prop = &schema["inputSchema"]["properties"]["steps"];
        assert_eq!(steps_prop["type"], "array");
    }

    #[test]
    fn tool_schema_for_parallel_run_has_array_type() {
        let spec = TOOL_SPECS.iter().find(|s| s.name == "parallel_run").unwrap();
        let schema = super::tool(spec);
        let steps_prop = &schema["inputSchema"]["properties"]["steps"];
        assert_eq!(steps_prop["type"], "array");
    }
}
