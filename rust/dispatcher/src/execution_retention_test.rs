use super::*;
use crate::mcp_execution::{new_id, save_record};
use std::os::unix::fs::symlink;

struct Fixture(ExecutionStore);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("makevn-retention-{}", new_id().unwrap()));
        fs::create_dir_all(root.join("locks")).unwrap();
        Self(ExecutionStore {
            root,
            session_id: new_id().unwrap(),
        })
    }

    fn record(&self, state: &str, end: u64) -> (String, Vec<File>) {
        let (mut record, locks) = self
            .0
            .prepare(&json!({"name":"doctor", "arguments":{"repo":self.0.root}}))
            .unwrap();
        record.state = state.into();
        record.started_at_ms = end - 100;
        record.duration_ms = 100;
        save_record(&self.0.root, &record).unwrap();
        fs::write(
            self.0
                .root
                .join(&record.execution_id)
                .join("supervisor.log"),
            "log",
        )
        .unwrap();
        (record.execution_id, locks)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0.root);
    }
}

#[test]
fn dry_run_and_cleanup_use_completion_age_and_report_counts() {
    let fixture = Fixture::new();
    let now = now_ms();
    let (id, locks) = fixture.record("succeeded", now - 4 * DAY_MS);
    drop(locks);
    let preview = cleanup_at(&fixture.0, 3, true, now).unwrap();
    assert_eq!(preview["executionIds"], json!([id]));
    assert_eq!(preview["logsDeleted"], 0);
    assert_eq!(preview["logPaths"].as_array().unwrap().len(), 1);
    assert!(fixture.0.get(&id).is_ok());
    let result = cleanup_at(&fixture.0, 3, false, now).unwrap();
    assert_eq!(result["executionsDeleted"], 1);
    assert_eq!(result["logsDeleted"], 1);
    assert!(!fixture.0.root.join(&id).exists());
    assert_eq!(
        cleanup_at(&fixture.0, 3, false, now).unwrap()["executionsDeleted"],
        0
    );
}

#[test]
fn retains_active_recent_boundary_and_future_executions() {
    let fixture = Fixture::new();
    let now = now_ms();
    let mut held = Vec::new();
    for (state, end, hold) in [
        ("running", now - 4 * DAY_MS, false),
        ("cancelled", now - 4 * DAY_MS, true),
        ("failed", now - 3 * DAY_MS, false),
        ("succeeded", now + DAY_MS, false),
    ] {
        let (_, locks) = fixture.record(state, end);
        if hold {
            held.extend(locks);
        }
    }
    assert_eq!(
        cleanup_at(&fixture.0, 3, false, now).unwrap()["executionsDeleted"],
        0
    );
}

#[test]
fn preserves_foreign_files_symlinks_and_untrusted_log_paths() {
    let fixture = Fixture::new();
    let now = now_ms();
    let foreign = fixture.0.root.join("foreign.log");
    fs::write(&foreign, "foreign").unwrap();
    for name in ["unrelated.txt", "0.stdout.log"] {
        let (id, locks) = fixture.record("failed", now - 4 * DAY_MS);
        drop(locks);
        let directory = fixture.0.root.join(&id);
        if name == "unrelated.txt" {
            fs::write(directory.join(name), "foreign").unwrap();
        } else {
            symlink(&foreign, directory.join(name)).unwrap();
        }
        let mut record = fixture.0.get(&id).unwrap();
        record
            .log_paths
            .push(foreign.to_string_lossy().into_owned());
        save_record(&fixture.0.root, &record).unwrap();
    }
    assert_eq!(
        cleanup_at(&fixture.0, 3, false, now).unwrap()["executionsDeleted"],
        0
    );
    assert_eq!(fs::read_to_string(foreign).unwrap(), "foreign");
}

#[test]
fn validates_retention_and_cli_arguments() {
    for args in [
        json!({"retentionDays":0}),
        json!({"retentionDays":-1}),
        json!({"retentionDays":1.5}),
        json!({"retentionDays":u64::MAX}),
    ] {
        assert!(retention_days(&args).is_err());
    }
    assert_eq!(retention_days(&json!({"retentionDays":7})).unwrap(), 7);
    assert!(parse_cli(vec!["--retention-days".into()]).is_err());
    assert!(parse_cli(vec!["--unknown".into()]).is_err());
    assert!(parse_cli(vec![
        "--retention-days".into(),
        "7".into(),
        "--dry-run".into()
    ])
    .unwrap()
    .is_some());
    assert!(parse_cli(vec!["--help".into()]).unwrap().is_none());
}

#[test]
fn automatic_cleanup_runs_before_admitting_new_work() {
    let fixture = Fixture::new();
    let (id, locks) = fixture.record("cancelled", now_ms() - 4 * DAY_MS);
    drop(locks);
    automatic(&fixture.0);
    let (_, active) = fixture
        .0
        .prepare(&json!({"name":"doctor","arguments":{"repo":fixture.0.root}}))
        .unwrap();
    assert!(!fixture.0.root.join(format!("{id}.json")).exists());
    assert_eq!(fixture.0.list(&json!({})).unwrap().len(), 1);
    drop(active);
}

#[test]
fn preserves_legacy_records_and_ignores_malformed_registry_entries() {
    let fixture = Fixture::new();
    let now = now_ms();
    let (id, locks) = fixture.record("failed", now - 4 * DAY_MS);
    drop(locks);
    let directory = fixture.0.root.join(&id);
    fs::remove_file(directory.join("lifetime.lock")).unwrap();
    fs::write(fixture.0.root.join("foreign.json"), "{}").unwrap();
    fs::write(
        fixture.0.root.join(format!("{}.json", new_id().unwrap())),
        "invalid",
    )
    .unwrap();
    fs::write(fixture.0.root.join("unrelated.txt"), "keep").unwrap();
    let linked = fixture.0.root.join(format!("{}.json", new_id().unwrap()));
    symlink(fixture.0.root.join(format!("{id}.json")), linked).unwrap();
    assert_eq!(
        cleanup_at(&fixture.0, 3, false, now).unwrap()["executionsDeleted"],
        0
    );
    assert!(directory.exists());
    assert!(cleanup(&fixture.0, &json!({"dryRun":"yes"})).is_err());
    assert!(!owned_name(".stdout.log"));
    assert!(!owned_name("word.stderr.log"));
    assert!(owned_name("1.phase"));
}
