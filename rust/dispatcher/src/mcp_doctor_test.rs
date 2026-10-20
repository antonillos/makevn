use serde_json::json;

#[test]
fn configure_requires_a_token_and_nonempty_answers() {
    for invalid in [json!({}), json!({"setupToken": "", "answers": {"local_containers": false}}),
        json!({"setupToken": "current", "answers": {}}), json!({"setupToken": "current", "answers": []})] {
        assert!(super::validate_arguments(&invalid).is_err());
    }
    assert!(super::validate_arguments(&json!({"setupToken": "current", "answers": {"local_containers": false}})).is_ok());
}

#[test]
fn doctor_exposes_questions_and_configure_in_the_mcp_contract() {
    let tools = crate::mcp_server::tools_list();
    let configure = tools.iter().find(|tool| tool["name"] == "doctor_configure").unwrap();
    assert_eq!(configure["inputSchema"]["properties"]["answers"], super::answers_schema());
    assert_eq!(configure["outputSchema"]["properties"]["interactive_setup"], super::setup_schema());
    assert!(!crate::mcp_execution::inspection("doctor_configure"));
}

#[test]
fn doctor_snapshot_survives_result_serialization() {
    let snapshot = json!({"interactive_setup": {"required": true, "status": "pending", "questions": [], "setupToken": "current"}, "suggested_next_step": {"next": "makevn init"}});
    let result = crate::mcp_server::ToolCallResult {
        output: "diagnostic".into(), exit_code: 0, duration_ms: 1,
        doctor_snapshot: Some(snapshot.clone()), next_suggestion: None,
    };
    let restored = serde_json::from_value(serde_json::to_value(result).unwrap()).unwrap();
    let response = crate::mcp_server::standard_tool_result(&restored, &json!({"name": "doctor"}));
    assert_eq!(response["structuredContent"]["interactive_setup"], snapshot["interactive_setup"]);
    assert_eq!(response["structuredContent"]["suggested_next_step"], snapshot["suggested_next_step"]);
}
