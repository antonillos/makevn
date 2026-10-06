use super::{push_tool_flags, resolve_makevn_bin, TOOL_SPECS};
use serde_json::{json, Map};
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process;
use std::time::{SystemTime, UNIX_EPOCH};

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
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("makevn-mcp-tool-call-{}-{nonce}", process::id()));
    fs::create_dir(&dir).unwrap();
    let bin = dir.join("makevn");
    let mut script = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&bin)
        .unwrap();
    script
        .write_all(b"#!/bin/sh\nprintf '%s\\n' \"$@\"\necho diagnostic >&2\nexit 7\n")
        .unwrap();
    drop(script);
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o700)).unwrap();

    let params = json!({"name": "doctor", "arguments": {"repo": "/tmp/example"}});
    let mut result = super::handle_tool_call(&bin, &params);
    // A concurrent test's fork can briefly inherit the fixture's write descriptor
    // before exec closes it. Linux rejects execution during that ETXTBSY window.
    // Retry only that transient fixture error; preserve every other failure.
    for _ in 0..20 {
        if !matches!(&result, Err(error) if error.contains("Text file busy (os error 26)")) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
        result = super::handle_tool_call(&bin, &params);
    }
    let result = result.unwrap();
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
fn tool_call_reports_success_and_unknown_tool_errors() {
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
    assert!(error.contains("unknown makevn tool: exec"));
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
fn tool_option_dispatch_preserves_type_filtering_and_command_errors() {
    let mut output = vec![];
    for name in [
        "apply",
        "clean-generated-contract-targets",
        "dry-run",
        "fast",
        "force",
        "verbose",
    ] {
        super::push_tool_option(&mut output, name, &json!(true)).unwrap();
        assert_eq!(output.pop().unwrap(), format!("--{name}"));
        super::push_tool_option(&mut output, name, &json!(false)).unwrap();
        super::push_tool_option(&mut output, name, &json!("true")).unwrap();
        assert!(output.is_empty());
    }
    for name in [
        "threshold",
        "overall-threshold",
        "max-warnings",
        "wait-seconds",
    ] {
        super::push_tool_option(&mut output, name, &json!(8.5)).unwrap();
        assert_eq!(output, vec![format!("--{name}"), "8.5".to_owned()]);
        output.clear();
        super::push_tool_option(&mut output, name, &json!("8")).unwrap();
        assert!(output.is_empty());
    }
    for name in ["base", "compose", "jacoco-xml", "module", "name", "tag"] {
        super::push_tool_option(&mut output, name, &json!("value")).unwrap();
        assert_eq!(output, vec![format!("--{name}"), "value".to_owned()]);
        output.clear();
        for value in [json!(""), json!(false), json!(null)] {
            super::push_tool_option(&mut output, name, &value).unwrap();
            assert!(output.is_empty());
        }
    }
    super::push_tool_option(&mut output, "unknown", &json!(true)).unwrap();
    assert!(output.is_empty());
}

#[test]
fn removed_exec_is_not_advertised_or_available_in_workflows() {
    assert!(!TOOL_SPECS.iter().any(|spec| spec.name == "exec"));
    for tool in ["composite_run", "parallel_run"] {
        let result = super::handle_tool_call(
            Path::new("/bin/echo"),
            &json!({"name": tool, "arguments": {"steps": [{"tool": "exec"}]}}),
        )
        .unwrap();
        assert!(result.output.contains("unknown makevn tool in step: exec"));
    }
}

#[test]
fn retired_make_tools_are_not_registered() {
    assert!(!TOOL_SPECS.iter().any(|s| s.name == "make_install"
        || s.name == "make_uninstall"
        || s.command.first() == Some(&"make")));
}

#[test]
fn all_tools_advertise_opt_in_trace_without_forwarding_it_to_cli() {
    for spec in TOOL_SPECS {
        let schema = super::tool(spec);
        let trace = &schema["inputSchema"]["properties"]["trace"];
        assert_eq!(trace["type"], "boolean");
        assert_eq!(trace["default"], false);
        let mut flags = Vec::new();
        let args = json!({"trace": true, "steps": []});
        push_tool_flags(&mut flags, spec, args.as_object().unwrap()).unwrap();
        assert!(flags.is_empty());
    }
}

#[test]
fn execution_metadata_is_always_visible_even_on_failure() {
    for exit_code in [0, 7] {
        let result = super::ToolCallResult {
            output: "command result or diagnostic".into(),
            exit_code,
            duration_ms: 42,
        };
        for args in [
            json!(null),
            json!({}),
            json!({"trace": false}),
            json!({"trace": true}),
            json!({"trace": "true"}),
        ] {
            let content =
                super::tool_result_content(&result, &json!({"name": "format", "arguments": args}));
            assert_eq!(content.len(), 2);
            assert_eq!(content[0], json!({"type": "text", "text": result.output}));
            let metadata: serde_json::Value =
                serde_json::from_str(content[1]["text"].as_str().unwrap()).unwrap();
            assert_eq!(
                metadata,
                json!({"tool": "format", "exitCode": exit_code, "durationMs": 42})
            );
        }
        let content = super::tool_result_content(
            &result,
            &json!({"name": "format", "arguments": {"trace": true}}),
        );
        assert_eq!(content.len(), 2);
        let trace: serde_json::Value =
            serde_json::from_str(content[1]["text"].as_str().unwrap()).unwrap();
        assert_eq!(
            trace,
            json!({"tool": "format", "exitCode": exit_code, "durationMs": 42})
        );
    }
}

#[test]
fn default_output_includes_zero_duration_workflow_metadata() {
    let result = super::ToolCallResult {
        output: "workflow summary".into(),
        exit_code: 0,
        duration_ms: 0,
    };
    let content = super::tool_result_content(&result, &json!({"name": "composite_run"}));
    assert_eq!(content.len(), 2);
    assert!(content[1]["text"]
        .as_str()
        .unwrap()
        .contains("\"durationMs\":0"));
}

#[test]
fn command_trace_is_opt_in_for_tools_and_workflow_steps() {
    let dir = std::env::temp_dir().join(format!(
        "makevn-trace-{}-{}",
        process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir(&dir).unwrap();
    let bin = dir.join("makevn");
    let runtime = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../libexec/makevn/common");
    fs::write(&bin, format!("#!/bin/bash\nsource '{}'\nsource '{}'\nmakevn_trace_command exec mvn test\necho '[ok] final result'\necho '[ERROR] diagnostic' >&2\nexit 7\n", runtime.join("ui.sh").display(), runtime.join("backend_logging.sh").display())).unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o700)).unwrap();
    for trace in [false, true] {
        let result = super::handle_tool_call(
            &bin,
            &json!({"name": "test", "arguments": {"trace": trace}}),
        )
        .unwrap();
        assert_eq!(result.exit_code, 7);
        assert_eq!(result.output.contains("→ exec mvn test"), trace);
        assert!(result.output.contains("[ok] final result"));
        assert!(result.output.contains("[ERROR] diagnostic"));
        for tool in ["composite_run", "parallel_run"] {
            let result = super::handle_tool_call(
                &bin,
                &json!({"name": tool, "arguments": {
                    "trace": trace, "fail-fast": false,
                    "steps": [{"tool": "test"}, {"tool": "test", "arguments": {"trace": !trace}}]
                }}),
            )
            .unwrap();
            let summary: serde_json::Value = serde_json::from_str(&result.output).unwrap();
            for (i, expected) in [trace, !trace].iter().enumerate() {
                let output = summary["steps"][i]["output"].as_str().unwrap();
                assert_eq!(output.contains("→ exec mvn test"), *expected);
                assert!(output.contains("final result"));
                assert!(output.contains("diagnostic"));
                assert_eq!(summary["steps"][i]["exitCode"], 7);
            }
        }
    }
    // CLI behavior stays unchanged when the MCP-only environment is absent.
    let output = std::process::Command::new(&bin)
        .env_remove("MAKEVN_TRACE_OUTPUT")
        .env("NO_COLOR", "1")
        .output()
        .unwrap();
    assert!(String::from_utf8_lossy(&output.stdout).contains("→ exec mvn test"));
    fs::remove_dir_all(dir).unwrap();
}
