use super::*;
use std::fs;
use std::os::unix::fs::symlink;

#[test]
fn cli_accepts_help_and_validates_snapshot_options() {
    assert!(cli(vec![]).is_err());
    assert!(cli(vec!["-h".into()]).is_ok());
    assert!(cli(vec!["01234567".into(), "--tail".into()]).is_err());
    let options = ["--step", "2", "--tail", "1", "--contains", "Tests run:"].map(OsString::from);
    assert_eq!(
        cli_options(&options).unwrap(),
        json!({"step":2,"tail":1,"contains":"Tests run:"})
    );
    for flags in [["--tail", "bad"], ["--step", "bad"], ["--unknown", "1"]] {
        assert!(cli_options(&flags.map(OsString::from)).is_err());
    }
}

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

    crate::mcp_execution::save_record(&root, &record).unwrap();
    print_snapshot(&store, &id, &json!({"step":1})).unwrap();
    assert_eq!(resolve_id(&store, &id[..8].to_uppercase()).unwrap(), id);
    assert_eq!(resolve_id(&store, &id).unwrap(), id);
    assert!(resolve_id(&store, "../bad-id")
        .unwrap_err()
        .contains("hexadecimal"));
    let absent = format!(
        "{}{}",
        if id.starts_with('0') { "1" } else { "0" },
        &id[1..8]
    );
    assert!(resolve_id(&store, &absent)
        .unwrap_err()
        .contains("No execution found"));
    let other = format!(
        "{}{}",
        &id[..8],
        if id.ends_with('0') {
            "1".repeat(24)
        } else {
            "0".repeat(24)
        }
    );
    fs::write(root.join(format!("{other}.json")), "").unwrap();
    assert!(resolve_id(&store, &id[..8])
        .unwrap_err()
        .contains("Ambiguous"));

    fs::write(
        directory.join("1.stdout.log"),
        format!(
            "{}\nERROR first\nINFO info\nERROR last\n",
            "x".repeat(STREAM_BYTES as usize)
        ),
    )
    .unwrap();
    fs::write(directory.join("1.stderr.log"), "").unwrap();
    fs::write(
        directory.join("1.maven.log"),
        "Tests run: 4\nERROR failing test\n",
    )
    .unwrap();
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
    assert_eq!(logs["streams"][3]["stream"], "maven");
    assert_eq!(logs["streams"][3]["lines"], json!(["ERROR failing test"]));
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
