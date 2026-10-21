use super::*;

#[test]
fn cancellation_preserves_tool_guidance_and_mirrors_the_final_result() {
    for tool in ["docker_up", "docker_down", "docker_ps", "docker_stats",
        "docker_ps_required", "karate_docker_up", "karate_docker_down", "karate_all"] {
        let result = ToolCallResult {
            output: "startup interrupted".into(),
            exit_code: -1,
            duration_ms: 1,
            doctor_snapshot: None,
            next_suggestion: None,
        };
        let mut response = mcp_server::standard_tool_result(&result, &json!({"name": tool}));
        let original = response["structuredContent"]["nextSuggestion"].as_str().unwrap().to_owned();
        let record: ExecutionRecord = serde_json::from_value(json!({
            "executionId": "execution", "sessionId": "session", "command": tool,
            "repo": "/repo", "pr": null, "repositories": ["/repo"], "pullRequests": [],
            "startedAtMs": 0, "durationMs": 1, "state": "cancelled",
            "logPaths": ["supervisor.log"], "exitCode": -1, "currentPhase": null
        })).unwrap();

        add_identity(&mut response, &record);

        let data = &response["structuredContent"];
        let guidance = data["nextSuggestion"].as_str().unwrap();
        assert!(guidance.starts_with("Execution cancelled; inspect its preserved logs"));
        assert!(guidance.ends_with(&original));
        assert!(guidance.contains("Use MakeVN exclusively"));
        assert_eq!(data["executionState"], "cancelled");
        assert_eq!(data["logPaths"], json!(["supervisor.log"]));
        assert_eq!(data["exitCode"], -1);
        assert_eq!(response["isError"], true);
        let mirrored: Value = serde_json::from_str(response["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(&mirrored, data);
    }
}
