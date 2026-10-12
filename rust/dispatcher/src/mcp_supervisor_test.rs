use super::*;

#[test]
fn zombie_group_members_do_not_hold_execution_locks() {
    assert!(live_group_member("123 S", 123));
    assert!(live_group_member("123 R+", 123));
    assert!(!live_group_member("123 Z", 123));
    assert!(!live_group_member("124 S", 123));
    assert!(!live_group_member("invalid", 123));
}

#[test]
fn cancelled_without_supervisor_is_false() {
    assert!(!cancelled());
    let output = command_output(Command::new("printf").arg("sample"), false).unwrap();
    assert!(output.status.success());
    assert_eq!(output.stdout, b"sample");
}

#[test]
fn queued_cancellation_and_owner_loss_never_admit_a_command() {
    use crate::mcp_execution::{new_id, ExecutionStore};
    use serde_json::json;
    for input in [b"C".as_slice(), b"".as_slice()] {
        let root = std::env::temp_dir().join(format!("makevn-supervisor-{}", new_id().unwrap()));
        fs::create_dir_all(root.join("locks")).unwrap();
        let store = ExecutionStore {
            root: root.clone(),
            session_id: new_id().unwrap(),
        };
        let (record, _) = store
            .prepare(&json!({"name":"doctor", "arguments":{"repo":root}}))
            .unwrap();
        let worker = ExecutionWorker {
            root: root.clone(),
            record: Mutex::new(record),
            cancelled: AtomicBool::new(false),
            cancellation_started: OnceLock::new(),
            command_index: AtomicUsize::new(0),
        };
        assert!(!admit(&mut io::Cursor::new(input), &worker).unwrap());
        assert!(worker.cancelled.load(Ordering::SeqCst));
        assert_eq!(worker.record.lock().unwrap().state, "cancelling");
        worker.cancel();
        assert_eq!(worker.record.lock().unwrap().state, "cancelling");
        worker
            .update(|record| record.state = "succeeded".into())
            .unwrap();
        worker.cancelled.store(false, Ordering::SeqCst);
        worker.cancel();
        assert!(!worker.cancelled.load(Ordering::SeqCst));
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn telemetry_reads_only_appended_lines_and_persists_only_changes() {
    use crate::mcp_execution::{new_id, ExecutionStore};
    use serde_json::json;
    let root = std::env::temp_dir().join(format!("makevn-telemetry-{}", new_id().unwrap()));
    fs::create_dir_all(root.join("locks")).unwrap();
    let store = ExecutionStore {
        root: root.clone(),
        session_id: new_id().unwrap(),
    };
    let (record, _locks) = store
        .prepare(&json!({"name":"doctor","arguments":{"repo":root}}))
        .unwrap();
    let record_path = root.join(format!("{}.json", record.execution_id));
    let worker = ExecutionWorker {
        root: root.clone(),
        record: Mutex::new(record),
        cancelled: AtomicBool::new(false),
        cancellation_started: OnceLock::new(),
        command_index: AtomicUsize::new(0),
    };
    let stdout = root.join("stdout");
    let phase = root.join("phase");
    fs::write(&stdout, "[..] makevn verify | log: ").unwrap();
    fs::write(&phase, "testing\n").unwrap();
    let mut tail = OutputTail::default();
    assert!(tail.read(&stdout).is_empty());
    let mut output = OpenOptions::new().append(true).open(&stdout).unwrap();
    writeln!(output, "verify.log").unwrap();
    let added = tail.read(&stdout);
    worker.refresh(&added, &phase);
    assert!(worker
        .record
        .lock()
        .unwrap()
        .log_paths
        .contains(&"verify.log".into()));
    assert_eq!(
        worker.record.lock().unwrap().current_phase.as_deref(),
        Some("testing")
    );
    assert!(tail.read(&stdout).is_empty());
    // A no-change refresh must not recreate a removed metadata file.
    fs::remove_file(&record_path).unwrap();
    worker.refresh(&added, &phase);
    assert!(!record_path.exists());
    writeln!(output, "[..] makevn verify | log: another.log").unwrap();
    assert_eq!(
        tail.read(&stdout),
        "[..] makevn verify | log: another.log\n"
    );
    fs::write(&phase, "reporting\n").unwrap();
    worker.refresh("", &phase);
    assert!(record_path.exists());
    fs::remove_dir_all(root).unwrap();
}
