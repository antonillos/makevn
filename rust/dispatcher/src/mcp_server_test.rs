use super::{exec_timeout_seconds, push_tool_flags, resolve_makevn_bin, TOOL_SPECS};
use serde_json::{json, Map};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process;

#[test]
fn resolves_sibling_makevn_or_current_binary() {
    let dir = std::env::temp_dir().join(format!("makevn-mcp-bin-test-{}", process::id()));
    fs::create_dir_all(&dir).unwrap();
    let mcp = dir.join("makevn-mcp");
    let makevn = dir.join("makevn");
    assert!(resolve_makevn_bin(&mcp).is_err());
    fs::write(&makevn, b"").unwrap();
    assert_eq!(resolve_makevn_bin(&mcp).unwrap(), makevn);
    assert_eq!(resolve_makevn_bin(&makevn).unwrap(), makevn);
    fs::remove_file(&makevn).unwrap();
    assert_eq!(resolve_makevn_bin(&makevn).unwrap(), makevn);
    assert!(resolve_makevn_bin(Path::new("/")).is_err());
    fs::remove_dir(dir).unwrap();
}

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
fn exec_git_command_is_forwarded_verbatim_for_cli_validation() {
    let spec = TOOL_SPECS.iter().find(|spec| spec.name == "exec").unwrap();
    let mut args = Map::new();
    args.insert("context".into(), json!("code"));
    args.insert("command".into(), json!("git status"));
    let mut cmd_args = vec![String::from("exec")];

    push_tool_flags(&mut cmd_args, spec, &args).unwrap();

    assert_eq!(
        cmd_args,
        vec!["exec", "--context", "code", "--", "git", "status"]
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
fn crap_tool_has_typed_schema_and_forwards_flags() {
    let spec = TOOL_SPECS.iter().find(|s| s.name == "crap").unwrap();
    let schema = super::tool(spec);
    // MCP clients expose this server-scoped name as `makevn_crap`.
    assert_eq!(schema["name"], "crap");
    assert_eq!(
        schema["inputSchema"]["properties"]["jacoco-xml"]["type"],
        "string"
    );
    assert_eq!(
        schema["inputSchema"]["properties"]["threshold"]["type"],
        "number"
    );
    assert_eq!(
        schema["inputSchema"]["properties"]["max-warnings"]["type"],
        "integer"
    );

    let mut args = Map::new();
    args.insert("jacoco-xml".into(), json!("target/site/jacoco/jacoco.xml"));
    args.insert("threshold".into(), json!(8));
    args.insert("max-warnings".into(), json!(3));
    let mut cmd_args = vec![String::from("crap")];
    push_tool_flags(&mut cmd_args, spec, &args).unwrap();
    assert_eq!(
        cmd_args,
        vec![
            "crap",
            "--jacoco-xml",
            "target/site/jacoco/jacoco.xml",
            "--threshold",
            "8",
            "--max-warnings",
            "3"
        ]
    );
}

#[test]
fn crap_changes_tool_has_typed_schema_and_forwards_base() {
    let spec = TOOL_SPECS
        .iter()
        .find(|s| s.name == "crap_changes")
        .unwrap();
    let schema = super::tool(spec);
    assert_eq!(schema["name"], "crap_changes");
    assert_eq!(
        schema["inputSchema"]["properties"]["base"]["type"],
        "string"
    );
    let mut args = Map::new();
    args.insert("base".into(), json!("origin/develop"));
    let mut cmd_args = vec![String::from("crap-changes")];
    push_tool_flags(&mut cmd_args, spec, &args).unwrap();
    assert_eq!(cmd_args, vec!["crap-changes", "--base", "origin/develop"]);
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
    let spec = TOOL_SPECS
        .iter()
        .find(|s| s.name == "composite_run")
        .unwrap();
    let schema = super::tool(spec);
    let steps_prop = &schema["inputSchema"]["properties"]["steps"];
    assert_eq!(steps_prop["type"], "array");
}

#[test]
fn tool_schema_for_parallel_run_has_array_type() {
    let spec = TOOL_SPECS
        .iter()
        .find(|s| s.name == "parallel_run")
        .unwrap();
    let schema = super::tool(spec);
    let steps_prop = &schema["inputSchema"]["properties"]["steps"];
    assert_eq!(steps_prop["type"], "array");
}

#[test]
fn tool_call_validates_name_and_composite_steps() {
    let bin = Path::new("/nonexistent/makevn");
    assert!(super::handle_tool_call(bin, &json!({}))
        .err()
        .unwrap()
        .contains("missing tool name"));
    assert!(super::handle_tool_call(bin, &json!({"name": "unknown"}))
        .err()
        .unwrap()
        .contains("unknown makevn tool"));
    assert!(
        super::handle_tool_call(bin, &json!({"name": "composite_run"}))
            .err()
            .unwrap()
            .contains("steps")
    );
    assert!(
        super::handle_tool_call(bin, &json!({"name": "parallel_run"}))
            .err()
            .unwrap()
            .contains("steps")
    );
}

#[test]
fn tool_call_forwards_arguments_and_reports_process_failure() {
    let dir = std::env::temp_dir().join(format!("makevn-mcp-tool-call-{}", process::id()));
    fs::create_dir_all(&dir).unwrap();
    let bin = dir.join("makevn");
    fs::write(
        &bin,
        b"#!/bin/sh\nprintf '%s\\n' \"$@\"\necho diagnostic >&2\nexit 7\n",
    )
    .unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o700)).unwrap();

    let result = super::handle_tool_call(
        &bin,
        &json!({"name": "doctor", "arguments": {"repo": "/tmp/example"}}),
    )
    .unwrap();
    assert_eq!(result.exit_code, 7);
    assert!(result
        .output
        .contains("--repo\n/tmp/example\n--compact\ndoctor"));
    assert!(result.output.contains("diagnostic"));
    assert!(result.output.contains("exit code 7"));

    fs::remove_file(bin).unwrap();
    fs::remove_dir(dir).unwrap();
}

#[test]
fn tool_call_reports_success_and_exec_argument_errors() {
    let result = super::handle_tool_call(
        Path::new("/bin/echo"),
        &json!({"name": "doctor", "arguments": {"repo": ""}}),
    )
    .unwrap();
    assert_eq!(result.exit_code, 0);
    assert_eq!(result.output, "--compact doctor");

    let error = super::handle_tool_call(
        Path::new("/bin/echo"),
        &json!({"name": "exec", "arguments": {"command": "mvn -v", "timeout-seconds": 0}}),
    )
    .err()
    .unwrap();
    assert!(error.contains("timeout-seconds"));
}

#[test]
fn composite_run_stops_on_error_unless_fail_fast_is_disabled() {
    let steps = json!([
        {"tool": "unknown"},
        {"tool": "doctor", "arguments": {"repo": "/step"}}
    ]);
    let stopped = super::handle_tool_call(
        Path::new("/bin/echo"),
        &json!({"name": "composite_run", "arguments": {"steps": steps}}),
    )
    .unwrap();
    let stopped: serde_json::Value = serde_json::from_str(&stopped.output).unwrap();
    assert_eq!(stopped["executed_steps"], 1);
    assert_eq!(stopped["failed"], true);
    assert_eq!(stopped["steps"][0]["exitCode"], -1);

    let continued = super::handle_tool_call(
        Path::new("/bin/echo"),
        &json!({"name": "composite_run", "arguments": {
            "steps": steps, "fail-fast": false, "repo": "/global"
        }}),
    )
    .unwrap();
    let continued: serde_json::Value = serde_json::from_str(&continued.output).unwrap();
    assert_eq!(continued["executed_steps"], 2);
    assert_eq!(continued["steps"][1]["exitCode"], 0);
    assert!(continued["steps"][1]["output"]
        .as_str()
        .unwrap()
        .contains("--repo /step"));
}

#[test]
fn composite_run_stops_on_nonzero_exit_and_can_continue() {
    let steps = json!([{"tool": "doctor"}, {"tool": "doctor"}]);
    let stopped = super::handle_tool_call(
        Path::new("/usr/bin/false"),
        &json!({"name": "composite_run", "arguments": {"steps": steps}}),
    )
    .unwrap();
    let stopped: serde_json::Value = serde_json::from_str(&stopped.output).unwrap();
    assert_eq!(stopped["executed_steps"], 1);
    assert_eq!(stopped["steps"][0]["exitCode"], 1);

    let continued = super::handle_tool_call(
        Path::new("/usr/bin/false"),
        &json!({"name": "composite_run", "arguments": {
            "steps": steps, "fail-fast": false
        }}),
    )
    .unwrap();
    let continued: serde_json::Value = serde_json::from_str(&continued.output).unwrap();
    assert_eq!(continued["executed_steps"], 2);
    assert_eq!(continued["exitCode"], 1);
}

#[test]
fn parallel_run_reports_success_and_invalid_steps_in_input_order() {
    let result = super::handle_tool_call(
        Path::new("/bin/echo"),
        &json!({"name": "parallel_run", "arguments": {
            "repo": "/global",
            "steps": [{"tool": "doctor"}, {"tool": "unknown"}]
        }}),
    )
    .unwrap();
    let summary: serde_json::Value = serde_json::from_str(&result.output).unwrap();
    assert_eq!(summary["total_steps"], 2);
    assert_eq!(summary["failed"], true);
    assert_eq!(summary["steps"][0]["exitCode"], 0);
    assert!(summary["steps"][0]["output"]
        .as_str()
        .unwrap()
        .contains("--repo /global"));
    assert_eq!(summary["steps"][1]["exitCode"], -1);
}

#[test]
fn timed_execution_captures_output_and_stops_overdue_processes() {
    let output =
        super::run_makevn_with_timeout(Path::new("/bin/echo"), &[String::from("hello")], 1)
            .unwrap();
    assert_eq!(output.stdout, b"hello\n");
    assert!(output.stderr.is_empty());
    assert!(output.status.success());
    assert!(!output.timed_out);

    let output = super::run_makevn_with_timeout(
        Path::new("/bin/sh"),
        &[String::from("-c"), String::from("sleep 3")],
        1,
    )
    .unwrap();
    assert!(output.timed_out);
    assert!(!output.status.success());
}
