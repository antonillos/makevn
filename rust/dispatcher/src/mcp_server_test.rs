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
fn composite_run_rejects_invalid_steps_even_when_fail_fast_is_disabled() {
    for fail_fast in [true, false] {
        let error = super::handle_tool_call(
            Path::new("/bin/echo"),
            &json!({"name":"composite_run", "arguments":{"fail-fast":fail_fast,
                "steps":[{"tool":"clean"},{"tool":"unknown"}]}}),
        ).err().unwrap();
        assert!(error.contains("step 2: unknown makevn tool"));
    }
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
    assert_eq!(stopped["executedSteps"], 1);
    assert_eq!(stopped["steps"][0]["exitCode"], 1);

    let continued = super::handle_tool_call(
        Path::new("/usr/bin/false"),
        &json!({"name": "composite_run", "arguments": {
            "steps": steps, "fail-fast": false
        }}),
    )
    .unwrap();
    let continued: serde_json::Value = serde_json::from_str(&continued.output).unwrap();
    assert_eq!(continued["executedSteps"], 2);
    assert_eq!(continued["exitCode"], 1);
}

#[test]
fn parallel_run_reports_valid_steps_in_input_order() {
    let result = super::handle_tool_call(
        Path::new("/bin/echo"),
        &json!({"name": "parallel_run", "arguments": {
            "repo": "/global",
            "steps": [{"tool": "doctor"}, {"tool": "verify_ut"}]
        }}),
    )
    .unwrap();
    let summary: serde_json::Value = serde_json::from_str(&result.output).unwrap();
    assert_eq!(summary["totalSteps"], 2);
    assert_eq!(summary["failed"], false);
    assert_eq!(summary["steps"][0]["exitCode"], 0);
    assert!(summary["steps"][0]["output"]
        .as_str()
        .unwrap()
        .contains("--repo /global"));
    assert_eq!(summary["steps"][1]["exitCode"], 0);
}

#[test]
fn tool_option_dispatch_preserves_type_filtering_and_command_errors() {
    let mut output = vec![];
    for name in [
        "apply",
        "clean-generated-contract-targets",
        "dry-run",
        "fast",
        "focused",
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
        .err().unwrap();
        assert!(result.contains("unknown makevn tool in step: exec"));
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
        let description = trace["description"].as_str().unwrap();
        assert!(description.contains("user explicitly asks"));
        assert!(description.contains("exact executed command"));
        assert!(description.contains("failure diagnosis"));
        assert!(description.contains("do not carry true"));
        let mut flags = Vec::new();
        let args = json!({"trace": true, "steps": []});
        push_tool_flags(&mut flags, spec, args.as_object().unwrap()).unwrap();
        assert!(flags.is_empty());
    }
}

#[test]
fn structured_results_preserve_metadata_and_text_fallback() {
    for exit_code in [0, 7, -1] {
        let result = super::ToolCallResult {
            output: "command result or diagnostic".into(),
            exit_code,
            duration_ms: 42,
            next_suggestion: None,
        };
        let response = super::standard_tool_result(&result, &json!({"name": "format"}));
        assert_eq!(response["isError"], exit_code != 0);
        let data = &response["structuredContent"];
        assert_eq!(data["exitCode"], exit_code);
        assert_eq!(data["durationMs"], 42);
        assert_eq!(data["untrustedData"]["output"], result.output);
        assert_eq!(data["untrustedData"]["workflow"], json!(null));
        let fallback: serde_json::Value =
            serde_json::from_str(response["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(&fallback, data);
        assert!(data["nextSuggestion"].as_str().unwrap().len() > 10);
    }
}

#[test]
fn tools_advertise_shared_output_schema() {
    for spec in TOOL_SPECS {
        assert_eq!(super::tool(spec)["outputSchema"], super::result_schema());
    }
}

#[test]
fn workflow_failure_reaches_outer_result_and_collects_logs() {
    for tool in ["composite_run", "parallel_run"] {
        let params = json!({"name": tool, "arguments": {"steps": [{"tool": "doctor"}]}});
        let result = super::handle_tool_call(Path::new("/usr/bin/false"), &params).unwrap();
        assert_eq!(result.exit_code, 1);
        let response = super::standard_tool_result(&result, &params);
        assert_eq!(response["isError"], true);
        assert_eq!(
            response["structuredContent"]["untrustedData"]["workflow"]["steps"][0]["exitCode"],
            1
        );
    }
    let result = super::ToolCallResult {
        output: json!({"steps": [{"logPaths": ["a", "b"]}, {"logPaths": ["a"]}]}).to_string(),
        exit_code: 0,
        duration_ms: 5,
        next_suggestion: None,
    };
    let response = super::standard_tool_result(&result, &json!({"name": "parallel_run"}));
    assert_eq!(response["structuredContent"]["logPaths"], json!(["a", "b"]));
}

#[test]
fn protocol_negotiation_supports_modern_and_legacy_clients() {
    for version in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"] {
        assert_eq!(
            super::negotiated_protocol(&json!({"protocolVersion": version})),
            version
        );
    }
    assert_eq!(
        super::negotiated_protocol(&json!({"protocolVersion": "unknown"})),
        "2025-11-25"
    );
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
    fs::write(&bin, format!("#!/bin/bash\nsource '{}'\nsource '{}'\nsource '{}'\nmakevn_load_config '{}'\nmakevn_load_config '{}'\nmakevn_trace_command exec mvn test\necho '[..] makevn test | log: .makevn/logs/test.log'\necho '[ok] 1m 06s'\necho '[ok] 1m 07s'\necho '[ok] final result'\necho '[ERROR] diagnostic' >&2\nexit 7\n", runtime.join("ui.sh").display(), runtime.join("backend_logging.sh").display(), runtime.join("core.sh").display(), dir.display(), dir.display())).unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o700)).unwrap();
    fs::create_dir(dir.join(".makevn")).unwrap();
    for configured_trace in [0, 1] {
        fs::write(
            dir.join(".makevn/config"),
            format!("MAKEVN_TRACE_OUTPUT={configured_trace}\n"),
        )
        .unwrap();
        for arguments in [json!({}), json!({"trace": false}), json!({"trace": true})] {
            let trace = arguments["trace"].as_bool().unwrap_or(false);
            let result =
                super::handle_tool_call(&bin, &json!({"name": "test", "arguments": arguments}))
                    .unwrap();
            assert_eq!(result.exit_code, 7);
            assert_eq!(result.output.contains("→ exec mvn test"), trace);
            assert_eq!(result.output.contains("[ok] 1m 06s"), trace);
            assert_eq!(result.output.contains("[ok] 1m 07s"), trace);
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
                    assert_eq!(output.contains("[ok] 1m 06s"), *expected);
                    assert_eq!(output.contains("[ok] 1m 07s"), *expected);
                    assert!(output.contains("final result"));
                    assert!(output.contains("diagnostic"));
                    assert_eq!(summary["steps"][i]["exitCode"], 7);
                    assert_eq!(
                        summary["steps"][i]["logPaths"],
                        json!([".makevn/logs/test.log"])
                    );
                    assert!(!output.contains("| log:"));
                }
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
    // Without an explicit caller selection, the repository setting still applies.
    fs::write(dir.join(".makevn/config"), "MAKEVN_TRACE_OUTPUT=0\n").unwrap();
    let output = std::process::Command::new(&bin)
        .env_remove("MAKEVN_TRACE_OUTPUT")
        .env("NO_COLOR", "1")
        .output()
        .unwrap();
    assert!(!String::from_utf8_lossy(&output.stdout).contains("→ exec mvn test"));
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn redundant_success_timings_are_hidden_without_trace_but_results_survive() {
    let output = "[..] makevn test | log: .makevn/logs/test.log\n[ok] 0s\n[ok] 1m 06s\n[ok] 1m 07s\n[ok] useful result\n[ERROR] test failed\nexit code 1\n{\"exitCode\":1}";
    assert_eq!(super::suppress_success_timings(output.into(), "1"), output);
    let filtered = super::suppress_success_timings(output.into(), "0");
    assert_eq!(filtered, "[..] makevn test | log: .makevn/logs/test.log\n[ok] useful result\n[ERROR] test failed\nexit code 1\n{\"exitCode\":1}");
    for line in [
        "[ok]",
        "[ok] ",
        "[ok] s",
        "[ok] 2s tests passed",
        "[ok] -1s",
        "[ok] 1.5s",
        "{\"message\":\"[ok] 2s\"}",
    ] {
        assert!(!super::is_success_timing(line), "must preserve: {line}");
    }
}

#[test]
fn log_headers_move_into_json_without_removing_diagnostics() {
    let output = "[..] makevn test | log: .makevn/logs/test.log\n[ERROR] failure\n[..] makevn compile | log: .makevn/logs/compile.log\n[..] makevn test | log: .makevn/logs/test.log\nsummary: report.xml\n{\"result\":1}";
    let expected_output = "[ERROR] failure\nsummary: report.xml\n{\"result\":1}";
    for trace in [false, true] {
        let result = super::ToolCallResult {
            output: output.into(),
            exit_code: 1,
            duration_ms: 42,
            next_suggestion: None,
        };
        let content = super::standard_tool_result(
            &result,
            &json!({"name": "test", "arguments": {"trace": trace}}),
        );
        assert_eq!(
            content["structuredContent"]["untrustedData"]["output"],
            expected_output
        );
        let metadata: serde_json::Value = content["structuredContent"].clone();
        assert_eq!(
            metadata["logPaths"],
            json!([".makevn/logs/test.log", ".makevn/logs/compile.log"])
        );
        assert_eq!(metadata["exitCode"], 1);
    }
    let step = super::step_result(0, "test", output, 1, 42);
    assert_eq!(step["output"], expected_output);
    assert_eq!(
        step["logPaths"],
        json!([".makevn/logs/test.log", ".makevn/logs/compile.log"])
    );
    for line in [
        "ordinary log: path",
        "[..] makevn test",
        "[..] makevn test | log: ",
        "{\"message\":\"[..] makevn test | log: file\"}",
    ] {
        assert_eq!(super::extract_log_headers(line), (line.into(), vec![]));
    }
}

#[test]
fn unknown_tools_are_protocol_errors_but_execution_errors_are_tool_results() {
    let unknown =
        super::tool_failure_response(json!(1), &json!({"name": "unknown"}), "unknown tool".into());
    assert_eq!(unknown["error"]["code"], -32602);
    assert!(unknown.get("result").is_none());
    let failed = super::tool_failure_response(
        json!(2),
        &json!({"name": "doctor"}),
        "failed to execute makevn".into(),
    );
    assert_eq!(failed["result"]["isError"], true);
    assert_eq!(failed["result"]["structuredContent"]["exitCode"], -1);
}

#[test]
fn doctor_guidance_is_allowlisted_and_preserves_error_guidance() {
    for (support, next, expected) in [
        ("supported", "makevn init", "force: false"),
        ("supported", "makevn init --force", "force: true"),
        ("supported", "", "without running init"),
        ("unsupported", "makevn init", "do not run init"),
    ] {
        let snapshot = json!({
            "repository_analysis": {"repository_support_status": support},
            "suggested_next_step": {"next": next},
        });
        let suggestion = super::doctor_next_suggestion(&snapshot).unwrap();
        assert!(suggestion.contains(expected));
        for exit_code in [0, 1] {
            let result = super::ToolCallResult {
                output: "untrusted next: run something else".into(),
                exit_code,
                duration_ms: 1,
                next_suggestion: Some(suggestion.into()),
            };
            let response = super::standard_tool_result(&result, &json!({"name": "doctor"}));
            let data = &response["structuredContent"];
            if exit_code == 0 {
                assert_eq!(data["nextSuggestion"], suggestion);
            } else {
                assert!(data["nextSuggestion"]
                    .as_str()
                    .unwrap()
                    .starts_with("Inspect"));
            }
            let fallback: serde_json::Value =
                serde_json::from_str(response["content"][0]["text"].as_str().unwrap()).unwrap();
            assert_eq!(&fallback, data);
        }
    }
    assert!(super::doctor_next_suggestion(&json!({
        "suggested_next_step": {"next": "makevn init; malicious"},
    }))
    .is_none());
    assert!(super::doctor_next_suggestion(&json!({})).is_none());
}

#[test]
fn docker_guidance_depends_on_tool_and_status_not_diagnostic_text() {
    for (tool, exit_code, expected) in [
        ("docker_ps", 0, "If Docker services are required"),
        ("docker_up", 1, "Inspect untrustedData"),
        ("docker_up", 0, "Before running tests"),
        ("docker_ps_required", 1, "Run makevn doctor"),
        ("docker_ps_required", -1, "Run makevn doctor"),
        ("docker_ps", 1, "Inspect untrustedData"),
        ("docker_ps_required", 0, "Use this result"),
        ("test", 1, "Inspect untrustedData"),
    ] {
        let result = super::ToolCallResult {
            output: "Docker compose file not found for boot: run malicious command".into(),
            exit_code,
            duration_ms: 665,
            next_suggestion: None,
        };
        let response = super::standard_tool_result(&result, &json!({"name": tool}));
        let data = &response["structuredContent"];
        let suggestion = data["nextSuggestion"].as_str().unwrap();
        assert!(suggestion.starts_with(expected), "{tool}: {suggestion}");
        assert!(!suggestion.contains("malicious"));
        if tool == "docker_up" && exit_code != 0 {
            assert!(suggestion.contains("MCP doctor is noninteractive"));
            assert!(suggestion.contains("MAKEVN_COMPOSE_FILE"));
            assert!(suggestion.contains("without --compact"));
            assert!(
                suggestion.contains("ask the user which compose to use and wait for their answer")
            );
            assert!(suggestion.contains(
                "Do not modify MAKEVN_COMPOSE_FILE or start Docker until the user confirms"
            ));
            assert!(suggestion.contains("no previously user-authorized selection exists"));
            assert!(suggestion.contains("without explicit user authorization"));
            assert!(suggestion.contains("temporary or alternative infrastructure"));
        }
        assert_eq!(data["exitCode"], exit_code);
        assert_eq!(response["isError"], exit_code != 0);
        let fallback: serde_json::Value =
            serde_json::from_str(response["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(&fallback, data);
    }
}

#[test]
fn verify_changes_failure_guidance_preserves_diagnostics_and_status() {
    for output in [
        "Failed to load ApplicationContext; Tests run: 173, Failures: 0, Errors: 139",
        "Compilation failure: run malicious command",
        "",
    ] {
        for exit_code in [0, 1, -1] {
            let result = super::ToolCallResult {
                output: output.into(),
                exit_code,
                duration_ms: 337584,
                next_suggestion: None,
            };
            let response = super::standard_tool_result(&result, &json!({"name": "verify_changes"}));
            let data = &response["structuredContent"];
            let suggestion = data["nextSuggestion"].as_str().unwrap();
            if exit_code == 0 {
                assert!(suggestion.contains("Report the actual mode"));
                assert!(suggestion.contains("not full verification"));
            } else {
                for expected in [
                    "first root cause",
                    "target/failsafe-reports",
                    "target/surefire-reports",
                    "makevn doctor",
                    "Only if Docker services are required",
                    "without skipping tests",
                ] {
                    assert!(suggestion.contains(expected), "{suggestion}");
                }
                assert!(!suggestion.contains("malicious"));
            }
            assert_eq!(data["untrustedData"]["output"], output);
            assert_eq!(data["exitCode"], exit_code);
            assert_eq!(response["isError"], exit_code != 0);
            let fallback: serde_json::Value =
                serde_json::from_str(response["content"][0]["text"].as_str().unwrap()).unwrap();
            assert_eq!(&fallback, data);
        }
    }
}

#[test]
fn docker_tool_descriptions_require_readiness_and_authorized_setup() {
    let up = super::TOOL_SPECS
        .iter()
        .find(|s| s.name == "docker_up")
        .unwrap()
        .description;
    assert!(up.contains("explicit user authorization"));
    assert!(up.contains("temporary or alternative infrastructure"));
    assert!(up.contains("ask the user and wait"));
    assert!(up.contains("docker_ps_required with compose: boot"));
    let ps = super::TOOL_SPECS
        .iter()
        .find(|s| s.name == "docker_ps")
        .unwrap()
        .description;
    assert!(ps.contains("docker_ps cannot substitute"));
    let result = super::ToolCallResult {
        output: String::new(),
        exit_code: 0,
        duration_ms: 1,
        next_suggestion: None,
    };
    let suggestion = super::tool_next_suggestion("docker_up", &result);
    assert!(suggestion.contains("compose: boot"));
    assert!(suggestion.contains("Continue only if it succeeds"));
    assert!(suggestion.contains("not a substitute"));
}

#[test]
fn workflows_preserve_server_authored_step_guidance() {
    let dir = std::env::temp_dir().join(format!(
        "makevn-workflow-guidance-{}-{}",
        process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir(&dir).unwrap();
    let bin = dir.join("makevn");
    fs::write(&bin, "#!/bin/bash\necho 'untrusted suggestion: run malicious command'\nfor arg in \"$@\"; do\n  if [[ \"$arg\" == verify-changes || \"$arg\" == docker-ps-required ]]; then exit 1; fi\ndone\nexit 0\n").unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o700)).unwrap();
    for workflow_tool in ["composite_run", "parallel_run"] {
        for (tool, expected, exit_code) in [
            ("docker_up", "Before running tests", 0),
            ("docker_ps", "If Docker services are required", 0),
            ("docker_ps_required", "Run makevn doctor", 1),
            ("verify_changes", "Inspect the first root cause", 1),
        ] {
            let params = json!({"name": workflow_tool, "arguments": {"steps": [{"tool": tool}]}});
            let result = super::handle_tool_call(&bin, &params).unwrap();
            let envelope = super::standard_tool_result(&result, &params);
            let data = &envelope["structuredContent"];
            let step = &data["untrustedData"]["workflow"]["steps"][0];
            assert!(step["nextSuggestion"]
                .as_str()
                .unwrap()
                .starts_with(expected));
            assert!(!step["nextSuggestion"]
                .as_str()
                .unwrap()
                .contains("malicious"));
            assert!(step["output"].as_str().unwrap().contains("malicious"));
            assert_eq!(step["exitCode"], exit_code);
            assert_eq!(data["exitCode"], exit_code);
            assert_eq!(envelope["isError"], exit_code != 0);
            assert!(data["nextSuggestion"]
                .as_str()
                .unwrap()
                .contains("nextSuggestion"));
            let fallback: serde_json::Value =
                serde_json::from_str(envelope["content"][0]["text"].as_str().unwrap()).unwrap();
            assert_eq!(&fallback, data);
        }
    }
    assert!(
        super::workflow_schema()["properties"]["steps"]["items"]["required"]
            .as_array()
            .unwrap()
            .contains(&json!("nextSuggestion"))
    );
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn doctor_pending_questions_require_interactive_cli_not_mcp_retry() {
    for next in ["makevn init", "makevn init --force", ""] {
        let snapshot = json!({"repository_analysis": {"repository_support_status": "supported"}, "suggested_next_step": {"next": next}, "interactive_setup": {"required": true}});
        let suggestion = super::doctor_next_suggestion(&snapshot).unwrap();
        for expected in [
            "launch the CLI command makevn doctor",
            "real interactive terminal/PTY",
            "Do NOT use MCP doctor again",
            "Let the user answer every prompt",
        ] {
            assert!(suggestion.contains(expected));
        }
    }
    assert!(super::doctor_next_suggestion(&json!({"repository_analysis": {"repository_support_status": "unsupported"}, "interactive_setup": {"required": true}})).unwrap().contains("do not run init"));
}

#[test]
fn pending_doctor_message_distinguishes_analysis_from_setup() {
    let snapshot = json!({"repository_analysis": {"repository_support_status": "supported"}, "interactive_setup": {"required": true}});
    let mut result = super::ToolCallResult {
        output: String::new(),
        exit_code: 0,
        duration_ms: 1,
        next_suggestion: super::doctor_next_suggestion(&snapshot).map(str::to_owned),
    };
    assert!(super::tool_result_message("doctor", &result).contains("configuration is pending"));
    assert_eq!(
        super::tool_result_message("test", &result),
        "makevn tool completed successfully."
    );
    result.exit_code = 1;
    assert!(super::tool_result_message("doctor", &result).contains("failed"));
    result.exit_code = 0;
    result.next_suggestion = None;
    assert_eq!(
        super::tool_result_message("doctor", &result),
        "makevn tool completed successfully."
    );
}

#[test]
fn focused_changes_option_is_exposed_in_both_tools() {
    for name in ["verify_changes", "verify_changes_preview"] {
        let spec = super::TOOL_SPECS.iter().find(|spec| spec.name == name).unwrap();
        assert!(spec.options.iter().any(|option| option.name == "focused"));
        assert!(spec.description.contains("focused"));
        assert!(spec.description.contains("gate"));
    }
}

#[test]
fn focused_agent_guidance_is_visible_without_loading_the_skill() {
    let result = super::ToolCallResult {
        output: String::new(), exit_code: 0, duration_ms: 1, next_suggestion: None,
    };
    let preview = super::tool_next_suggestion("verify_changes_preview", &result);
    for text in ["BOTH", "user need not name the flag", "large focused preparation reactor", "required full"] {
        assert!(preview.contains(text));
    }
    let verification = super::tool_next_suggestion("verify_changes", &result);
    for text in ["actual mode", "focused checks passed", "not full verification", "CRAP gates"] {
        assert!(verification.contains(text));
    }
}

#[test]
fn workflow_step_validation_rejects_silent_argument_loss() {
    for step in [
        json!({"tool":"clean","args":{}}),
        json!({"tool":"test","arguments":null}),
        json!({"tool":"test","arguments":[]}),
        json!({"tool":"verify_changes","arguments":{"focused":"true"}}),
        json!({"tool":"verify_changes","arguments":{"focussed":true}}),
        json!({"tool":"test","arguments":{"name":42}}),
        json!({"tool":"doctor","extra":true}),
        json!({"tool":"unknown"}), json!({"tool":"parallel_run"}),
        json!({"tool":42}), json!(false),
    ] {
        assert!(super::validate_workflow_step(&step).is_err(), "{step}");
    }
    assert!(super::validate_workflow_step(&json!({"tool":"verify_changes","arguments":{"focused":true,"trace":false}})).is_ok());
    assert!(super::validate_workflow_step(&json!({"tool":"clean"})).is_ok());
}

#[test]
fn workflow_validation_happens_before_clean_or_parallel_execution() {
    let args = json!({"steps":[{"tool":"clean"},{"tool":"verify_changes","args":{"focused":true}}]});
    // This executable cannot run: a validated workflow would instead return
    // execution failures. Both handlers must reject step 2 before launching any step.
    let nonexistent = Path::new("/makevn-test-executable-that-does-not-exist");
    for result in [super::handle_composite_run(nonexistent, args.as_object().unwrap()),
                   super::handle_parallel_run(nonexistent, args.as_object().unwrap())] {
        let error = result.unwrap_err();
        assert!(error.starts_with("step 2:"));
        assert!(error.contains("use 'arguments', not 'args'"));
    }
}

#[test]
fn workflow_descriptions_and_schema_teach_arguments_not_args() {
    for name in ["composite_run", "parallel_run"] {
        let spec = TOOL_SPECS.iter().find(|spec| spec.name == name).unwrap();
        let schema = super::tool(spec);
        let step = &schema["inputSchema"]["properties"]["steps"]["items"];
        assert_eq!(step["additionalProperties"], false);
        assert!(step["properties"].get("arguments").is_some());
        assert!(step["properties"].get("args").is_none());
        let description = schema["inputSchema"]["properties"]["steps"]["description"].as_str().unwrap();
        assert!(description.contains("\"arguments\""));
        assert!(!description.contains("\"args\""));
    }
    let composite = TOOL_SPECS.iter().find(|spec| spec.name == "composite_run").unwrap();
    for text in ["focused=true", "preview", "Do not add clean", "fail-fast=true"] {
        assert!(composite.description.contains(text));
    }
}

#[test]
fn step_option_types_match_all_supported_value_types() {
    for (ty, value) in [("boolean",json!(false)),("string",json!("repo")),
                        ("number",json!(1.5)),("integer",json!(2)),("array",json!([]))] {
        assert!(super::option_value_matches(ty, &value));
        assert!(!super::option_value_matches(ty, &json!(null)));
    }
    assert!(!super::option_value_matches("unknown", &json!(true)));
    assert!(!super::option_value_matches("integer", &json!(1.5)));
    assert!(super::option_value_matches("integer", &json!(u64::MAX)));
}

#[test]
fn valid_workflow_arguments_forward_focused_instead_of_defaulting() {
    let result = super::handle_tool_call(Path::new("/bin/echo"), &json!({
        "name":"composite_run", "arguments":{"steps":[
            {"tool":"verify_changes","arguments":{"focused":true}}
        ]}
    })).unwrap();
    let workflow: serde_json::Value = serde_json::from_str(&result.output).unwrap();
    assert!(workflow["steps"][0]["output"].as_str().unwrap().contains("--focused"));
}

#[test]
fn agent_templates_do_not_reintroduce_args_or_the_old_changes_pipeline() {
    for document in [include_str!("../../../docs/agents.md"),
                     include_str!("../../../skills/makevn/SKILL.md"),
                     include_str!("../../../mcp/README.md")] {
        assert!(!document.contains("\"args\":"));
    }
    let skill = include_str!("../../../skills/makevn/SKILL.md");
    let workflow = skill.split("### `changes-validator`").nth(1).unwrap()
        .split("### `multi-test-runner`").next().unwrap();
    assert!(workflow.contains("\"focused\": true"));
    assert!(!workflow.contains("{\"tool\": \"clean\"}"));
    assert!(!workflow.contains("{\"tool\": \"coverage_changes\"}"));
}
