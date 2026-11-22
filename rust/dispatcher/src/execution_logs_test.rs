use super::*;
use std::fs;
use std::io::Write;
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
    assert_eq!(
        cli_options(&["--cursor".into(), "token".into()]).unwrap(),
        json!({"cursor":"token"})
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
    assert_eq!(logs["streams"][0]["truncatedBeforeFilter"], true);
    assert_eq!(logs["streams"][0]["truncatedByTail"], true);
    let cursor = &logs["streams"][0]["nextCursor"];
    let arguments = json!({"step":1,"tail":1,"contains":"ERROR","cursor":cursor});
    let previous = read(&store, &record, &arguments).unwrap();
    assert_eq!(previous["streams"].as_array().unwrap().len(), 1);
    assert_eq!(previous["streams"][0]["stream"], "stdout");
    assert_eq!(previous["streams"][0]["lines"], json!(["ERROR first"]));
    assert!(read(&store, &record, &json!({"step":2,"cursor":cursor})).is_err());
    assert!(read(&store, &record, &json!({"cursor":"invalid"})).is_err());
    let wide = read(
        &store,
        &record,
        &json!({"step":1,"tail":400,"contains":"ERROR"}),
    )
    .unwrap();
    assert_eq!(wide["streams"][0]["truncatedBeforeFilter"], true);
    assert_eq!(wide["streams"][0]["truncatedByTail"], false);
    let tail_only = read(&store, &record, &json!({"step":1,"tail":1})).unwrap();
    assert_eq!(tail_only["streams"][3]["truncatedBeforeFilter"], false);
    assert_eq!(tail_only["streams"][3]["truncatedByTail"], true);
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

#[test]
fn cursor_reaches_matches_before_an_empty_page_and_ignores_appends() {
    let root = std::env::temp_dir().join(crate::mcp_execution::new_id().unwrap());
    fs::create_dir(&root).unwrap();
    let path = root.join("0.maven.log");
    let middle = "ordinary CRLF line\r\n".repeat(1000);
    fs::write(&path, format!("ERROR first\r\nERROR second\r\n{middle}")).unwrap();
    let directory = File::open(&root).unwrap();
    let mut query = PageQuery {
        execution: "example",
        step: 0,
        tail: 1,
        contains: Some("ERROR"),
        cursor: None,
    };
    let newest = query.read_stream(&directory, 3).unwrap();
    assert_eq!(newest.status, "no_matches");
    assert!(newest.clipped);
    OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(b"ERROR appended\n")
        .unwrap();

    query.cursor = Some(Cursor::parse(&json!(newest.cursor)).unwrap());
    let older = query.read_stream(&directory, 3).unwrap();
    assert_eq!(older.lines, ["ERROR second"]);
    assert!(older.limited);

    query.cursor = Some(Cursor::parse(&json!(older.cursor)).unwrap());
    let oldest = query.read_stream(&directory, 3).unwrap();
    assert_eq!(oldest.lines, ["ERROR first"]);
    assert!(oldest.cursor.is_none());

    fs::rename(&path, root.join("original.log")).unwrap();
    fs::write(&path, middle).unwrap();
    assert!(query
        .read_stream(&directory, 3)
        .err()
        .unwrap()
        .to_string()
        .contains("Log changed"));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn oversized_line_does_not_prevent_reaching_earlier_lines() {
    let input = format!("first\n{}\nlast\n", "x".repeat(3 * STREAM_BYTES as usize));
    let mut end = input.len();
    let mut partial = false;
    let mut lines = Vec::new();
    loop {
        let offset = end.saturating_sub(STREAM_BYTES as usize + 1);
        let page = select_page(
            &input.as_bytes()[offset..end],
            offset as u64,
            partial,
            100,
            None,
        );
        lines.extend(page.lines);
        let Some((next, next_partial)) = page.next else {
            break;
        };
        assert!(next < end as u64);
        end = next as usize;
        partial = next_partial;
    }
    assert_eq!(lines, ["last", "first"]);
}
