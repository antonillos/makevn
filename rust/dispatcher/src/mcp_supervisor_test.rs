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
