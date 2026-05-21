use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::process::Command;

use serde_json::{json, Value};

pub fn run_mcp_server(makevn_bin: PathBuf) -> Result<i32, String> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();

    for line in stdin.lock().lines() {
        let line = line.map_err(|e| format!("failed to read stdin: {e}"))?;
        let line = line.trim().to_owned();
        if line.is_empty() {
            continue;
        }

        let request: Value = serde_json::from_str(&line)
            .map_err(|e| format!("invalid JSON-RPC request: {e}"))?;

        let method = request["method"].as_str().unwrap_or("").to_owned();
        let id = request["id"].clone();
        let params = request["params"].clone();

        if method == "initialize" {
            let response = json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": { "tools": {} },
                    "serverInfo": {
                        "name": "makevn",
                        "version": "0.1.0"
                    }
                }
            });
            writeln!(stdout, "{}", serde_json::to_string(&response).unwrap()).map_err(|e| format!("write error: {e}"))?;
            stdout.flush().map_err(|e| format!("flush error: {e}"))?;
            continue;
        }

        if method == "notifications/initialized" {
            continue;
        }

        if method == "tools/list" {
            let response = json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": { "tools": tools_list() }
            });
            writeln!(stdout, "{}", serde_json::to_string(&response).unwrap()).map_err(|e| format!("write error: {e}"))?;
            stdout.flush().map_err(|e| format!("flush error: {e}"))?;
            continue;
        }

        if method == "tools/call" {
            let result = handle_tool_call(&makevn_bin, &params);
            let response = match result {
                Ok(content) => json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": { "content": [{"type": "text", "text": content}] }
                }),
                Err(err) => json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": { "code": -32603, "message": err }
                }),
            };
            writeln!(stdout, "{}", serde_json::to_string(&response).unwrap()).map_err(|e| format!("write error: {e}"))?;
            stdout.flush().map_err(|e| format!("flush error: {e}"))?;
            continue;
        }

        let response = json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32601, "message": format!("unknown method: {method}") }
        });
        writeln!(stdout, "{}", serde_json::to_string(&response).unwrap()).map_err(|e| format!("write error: {e}"))?;
        stdout.flush().map_err(|e| format!("flush error: {e}"))?;
    }

    Ok(0)
}

fn tools_list() -> Vec<Value> {
    vec![
        tool("doctor", "Inspect a Java/Maven repository. Run this first to understand the repo setup.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("init", "Initialize makevn in a repository. Creates .makevn/ configuration directory.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("dry-run", "boolean", "Show what would be done");
            b.opt("force", "boolean", "Force reinitialization");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("test", "Run tests with optional name filter and fast mode.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("name", "string", "Test class name or comma-separated names");
            b.opt("fast", "boolean", "Skip compilation when sources have not changed");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("verify", "Run full combined verification (unit tests + integration tests).", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("verify_ut", "Run unit-test-only verification.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("verify_it", "Run integration-test-only verification.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("verify_changes", "Verify only the changed production modules or tests.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("compile", "Compile the Maven project source code.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("build", "Full Maven build (compile, test, package).", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("coverage", "Check the latest JaCoCo aggregate coverage report.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("threshold", "number", "Coverage threshold percentage");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("coverage_changes", "Check incremental and per-module coverage.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("threshold", "number", "Per-module coverage threshold");
            b.opt("overall-threshold", "number", "Overall coverage threshold");
            b.opt("verbose", "boolean", "Verbose output");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("clean", "Clean Maven build output.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("package", "Compile and package without running tests.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("validate", "Validate the Maven project model.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("format", "Check or apply code formatting.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("apply", "boolean", "Apply formatting changes");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("exec", "Run an arbitrary command in the repository context.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.req("command", "string", "The command to execute, e.g. 'mvn -v'");
            b.opt("context", "string", "Execution context: 'code' or 'karate'");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("jdk_current", "Show the currently resolved JDK version.", |b| {
            b.opt("repo", "string", "Path to the repository");
        }),
        tool("docker_ps", "List running Docker containers for the compose setup.", |b| {
            b.opt("repo", "string", "Path to the repository");
        }),
        tool("docker_stats", "Show one-shot CPU and memory stats for all running Docker containers.", |b| {
            b.opt("repo", "string", "Path to the repository");
        }),
        tool("pr_verify", "Run a local PR-style verification flow.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("checkstyle", "Run Checkstyle code style checks.", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("module", "string", "Specific Maven module to check");
            b.opt("verbose", "boolean", "Verbose output");
            b.opt("compact", "boolean", "Use compact output");
        }),
        tool("mutation", "Run PIT mutation testing. Detects pitest-maven plugin automatically. WARNING: Very slow (30+ min for large projects).", |b| {
            b.opt("repo", "string", "Path to the repository");
            b.opt("module", "string", "Specific Maven module to test");
            b.opt("verbose", "boolean", "Show full Maven/PIT output (default: quiet)");
            b.opt("compact", "boolean", "Use compact output");
        }),
    ]
}

struct ToolBuilder {
    props: Vec<Value>,
    required: Vec<String>,
}

fn tool<F>(name: &str, description: &str, build: F) -> Value
where
    F: FnOnce(&mut ToolBuilder),
{
    let mut b = ToolBuilder {
        props: Vec::new(),
        required: Vec::new(),
    };
    build(&mut b);

    let mut schema = json!({
        "type": "object",
        "properties": {}
    });

    if let Some(props_obj) = schema.as_object_mut() {
        let properties = props_obj
            .get_mut("properties")
            .unwrap()
            .as_object_mut()
            .unwrap();
        for prop in &b.props {
            if let Some(key) = prop["name"].as_str() {
                let mut pd = json!({
                    "type": prop["type"].as_str().unwrap_or("string"),
                    "description": prop["description"].as_str().unwrap_or(""),
                });
                if let Some(obj) = pd.as_object_mut() {
                    if let Some(req) = prop["required"].as_bool() {
                        if req {
                            obj.insert("title".into(), json!("Required"));
                        }
                    }
                }
                properties.insert(key.into(), pd);
            }
        }
        if !b.required.is_empty() {
            props_obj.insert(
                "required".into(),
                json!(b.required.iter().map(|s| s.as_str()).collect::<Vec<_>>()),
            );
        }
    }

    json!({
        "name": name,
        "description": description,
        "inputSchema": schema
    })
}

impl ToolBuilder {
    fn opt(&mut self, name: &str, ty: &str, description: &str) {
        self.props.push(json!({
            "name": name,
            "type": ty,
            "description": description,
            "required": false
        }));
    }

    fn req(&mut self, name: &str, ty: &str, description: &str) {
        self.props.push(json!({
            "name": name,
            "type": ty,
            "description": description,
            "required": true
        }));
        self.required.push(name.into());
    }
}

fn handle_tool_call(makevn_bin: &PathBuf, params: &Value) -> Result<String, String> {
    let tool_name = params["name"].as_str().ok_or_else(|| String::from("missing tool name"))?;
    let args = params["arguments"].as_object().map(|m| m.clone()).unwrap_or_default();

    let mapped_name = tool_name.replace('_', "-");

    let mut cmd_args: Vec<String> = Vec::new();

    if let Some(repo) = args.get("repo").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
        cmd_args.push("--repo".into());
        cmd_args.push(repo.into());
    }

    cmd_args.push("--compact".into());

    if mapped_name == "exec" {
        cmd_args.push("exec".into());
        if let Some(ctx) = args.get("context").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
            cmd_args.push("--context".into());
            cmd_args.push(ctx.into());
        }
        cmd_args.push("--".into());
        if let Some(command) = args.get("command").and_then(|v| v.as_str()) {
            for part in command.split_whitespace() {
                cmd_args.push(part.into());
            }
        }
    } else if mapped_name == "coverage-changes" || mapped_name == "coverage_changes" {
        cmd_args.push("coverage-changes".into());
        if let Some(t) = args.get("threshold").and_then(|v| v.as_f64()) {
            cmd_args.push("--threshold".into());
            cmd_args.push(format!("{t}"));
        }
        if let Some(t) = args.get("overall-threshold").and_then(|v| v.as_f64()) {
            cmd_args.push("--overall-threshold".into());
            cmd_args.push(format!("{t}"));
        }
        if args.get("verbose").and_then(|v| v.as_bool()).unwrap_or(false) {
            cmd_args.push("--verbose".into());
        }
    } else if mapped_name == "jdk-current" || mapped_name == "jdk_current" {
        cmd_args.push("jdk".into());
        cmd_args.push("current".into());
    } else if mapped_name == "docker-ps" || mapped_name == "docker_ps" {
        cmd_args.push("docker-ps".into());
    } else if mapped_name == "docker-stats" || mapped_name == "docker_stats" {
        cmd_args.push("docker-stats".into());
    } else {
        cmd_args.push(mapped_name.clone());
        if mapped_name == "format" && args.get("apply").and_then(|v| v.as_bool()).unwrap_or(false) {
            cmd_args.push("--apply".into());
        }
        if mapped_name == "test" {
            if let Some(name) = args.get("name").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
                cmd_args.push("--name".into());
                cmd_args.push(name.into());
            }
            if args.get("fast").and_then(|v| v.as_bool()).unwrap_or(false) {
                cmd_args.push("--fast".into());
            }
        }
        if mapped_name == "checkstyle" {
            if let Some(m) = args.get("module").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
                cmd_args.push("--module".into());
                cmd_args.push(m.into());
            }
            if args.get("verbose").and_then(|v| v.as_bool()).unwrap_or(false) {
                cmd_args.push("--verbose".into());
            }
        }
        if mapped_name == "mutation" {
            if let Some(m) = args.get("module").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
                cmd_args.push("--module".into());
                cmd_args.push(m.into());
            }
            if args.get("verbose").and_then(|v| v.as_bool()).unwrap_or(false) {
                cmd_args.push("--verbose".into());
            }
        }
        if mapped_name == "coverage" {
            if let Some(t) = args.get("threshold").and_then(|v| v.as_f64()) {
                cmd_args.push("--threshold".into());
                cmd_args.push(format!("{t}"));
            }
        }
    }

    let output = Command::new(makevn_bin)
        .args(&cmd_args)
        .env("NO_COLOR", "1")
        .output()
        .map_err(|e| format!("failed to execute makevn: {e}"))?;

    let mut result = String::new();

    if !output.stdout.is_empty() {
        result.push_str(&String::from_utf8_lossy(&output.stdout).trim());
    }

    if !output.stderr.is_empty() {
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(&String::from_utf8_lossy(&output.stderr).trim());
    }

    if !output.status.success() {
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(&format!("exit code {}", output.status.code().unwrap_or(-1)));
    }

    Ok(result)
}
