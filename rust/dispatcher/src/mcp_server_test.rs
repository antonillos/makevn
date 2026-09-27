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
