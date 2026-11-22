use super::*;
use std::fs;
use std::os::unix::fs::symlink;

#[test]
fn snapshot_filters_and_bounds_each_stream_without_following_symlinks() {
    let root = std::env::temp_dir().join(crate::mcp_execution::new_id().unwrap());
    let id = crate::mcp_execution::new_id().unwrap();
    let directory = root.join(&id);
    crate::mcp_execution::private_directory(&directory).unwrap();
    let store = ExecutionStore {
        root: root.clone(),
        session_id: id.clone(),
    };
    let record: ExecutionRecord = serde_json::from_value(json!({
        "executionId":id,"sessionId":id,"command":"verify","repo":"/repo",
        "repositories":["/repo"],"pullRequests":[],"startedAtMs":0,"durationMs":0,
        "state":"failed","logPaths":["/arbitrary/file"],"exitCode":1
    }))
    .unwrap();

    fs::write(
        directory.join("1.stdout.log"),
        format!(
            "{}\nERROR first\nINFO info\nERROR last\n",
            "x".repeat(STREAM_BYTES as usize)
        ),
    )
    .unwrap();
    fs::write(directory.join("1.stderr.log"), "").unwrap();
    symlink(
        directory.join("1.stdout.log"),
        directory.join("supervisor.log"),
    )
    .unwrap();

    let logs = read(
        &store,
        &record,
        &json!({"step":1,"tail":1,"contains":"ERROR"}),
    )
    .unwrap();
    assert_eq!(logs["streams"][0]["lines"], json!(["ERROR last"]));
    assert_eq!(logs["streams"][0]["truncated"], true);
    assert_eq!(logs["streams"][1]["readStatus"], "empty");
    assert_eq!(logs["streams"][2]["readStatus"], "error");
    assert_eq!(
        read(&store, &record, &json!({"step":1,"contains":"absent"})).unwrap()["streams"][0]
            ["readStatus"],
        "no_matches"
    );
    assert_eq!(
        read(&store, &record, &json!({})).unwrap()["streams"][0]["readStatus"],
        "missing"
    );
    assert!(read(&store, &record, &json!({"tail":1001})).is_err());

    fs::remove_dir_all(root).unwrap();
}
