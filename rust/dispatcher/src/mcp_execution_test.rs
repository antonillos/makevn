use super::*;
use std::os::unix::fs::symlink;

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("makevn-execution-{}", new_id().unwrap()));
        fs::create_dir_all(path.join("locks")).unwrap();
        Self(path)
    }

    fn store(&self) -> ExecutionStore {
        ExecutionStore {
            root: self.0.clone(),
            session_id: new_id().unwrap(),
        }
    }

    fn params(&self, name: &str) -> Value {
        json!({"name": name, "arguments": {"repo": self.0}})
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn normalizes_pr_identity_without_network() {
    assert_eq!(
        normalize_pr("http://GitHub.COM:80/Owner/Repo/pull/00042/").unwrap(),
        "https://github.com/owner/repo/pull/42"
    );
    assert_eq!(
        normalize_pr("https://git.example:8443/A/B/pull/7").unwrap(),
        "https://git.example:8443/a/b/pull/7"
    );
    for invalid in [
        "file:///a/b/pull/1",
        "https://user@host/a/b/pull/1",
        "https://host/a/b/issues/1",
        "https://host/a/b/pull/0",
        "https://host/a/b/pull/no",
        "https://host/a/b/pull/1?x=y",
        "https://host//b/pull/1",
    ] {
        assert!(normalize_pr(invalid).is_err(), "{invalid}");
    }
}

#[test]
fn worktree_aliases_and_sessions_share_nonblocking_locks() {
    let fixture = Fixture::new();
    let first = fixture.store();
    let second = fixture.store();
    let (record, locks) = first.prepare(&fixture.params("verify_changes")).unwrap();
    let alias = fixture.0.join("alias");
    symlink(&fixture.0, &alias).unwrap();
    let params = json!({"name":"verify", "arguments":{"repo":alias}});
    let conflict = second.prepare(&params).err().unwrap();
    assert!(conflict.contains(&record.execution_id));
    assert!(conflict.contains(&record.session_id));
    assert!(second.prepare(&fixture.params("doctor")).is_ok());
    assert_eq!(second.list(&json!({})).unwrap().len(), 2);
    drop(locks);
    assert!(second.prepare(&params).is_ok());
}

#[test]
fn pr_locks_span_worktrees_but_other_prs_remain_independent() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let first = fixture.0.join("first");
    let second = fixture.0.join("second");
    fs::create_dir_all(&first).unwrap();
    fs::create_dir_all(&second).unwrap();
    let params =
        json!({"name":"verify", "arguments":{"repo":first,"pr":"https://github.com/a/b/pull/1"}});
    let (_, locks) = store.prepare(&params).unwrap();
    assert!(store.prepare(&json!({"name":"verify", "arguments":{"repo":second,"pr":"http://GITHUB.com/A/B/pull/01"}})).is_err());
    assert!(store.prepare(&json!({"name":"verify", "arguments":{"repo":second,"pr":"https://github.com/a/b/pull/2"}})).is_ok());
    drop(locks);
}

#[test]
fn workflow_acquires_every_worktree_and_pr_before_starting() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let other = fixture.0.join("other");
    fs::create_dir_all(&other).unwrap();
    let params = json!({"name":"composite_run", "arguments":{"repo":fixture.0,"steps":[
        {"tool":"doctor"}, {"tool":"verify", "arguments":{"repo":other,"pr":"https://host/a/b/pull/1"}}
    ]}});
    let (record, locks) = store.prepare(&params).unwrap();
    assert_eq!(record.repositories.len(), 2);
    assert_eq!(record.pull_requests.len(), 1);
    assert!(store
        .prepare(&json!({"name":"test","arguments":{"repo":other}}))
        .is_err());
    drop(locks);
    let (record, _) = store.prepare(&json!({"name":"parallel_run", "arguments":{"repo":fixture.0,"steps":[{"tool":"doctor"},{"tool":"verify_changes_preview"}]}})).unwrap();
    assert!(conflict_keys(&record, &json!({"arguments":{"steps":[{"tool":"doctor"}]}})).is_empty());
}

#[test]
fn records_preserve_terminal_state_and_reject_path_traversal() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let (mut record, _) = store.prepare(&fixture.params("doctor")).unwrap();
    record.state = "cancelled".into();
    record.exit_code = Some(130);
    record.duration_ms = 3;
    save_record(&fixture.0, &record).unwrap();
    assert!(store.list(&json!({})).unwrap().is_empty());
    let records = store
        .list(&json!({"includeFinished":true,"repo":fixture.0}))
        .unwrap();
    assert_eq!(records[0].duration_ms, 3);
    assert_eq!(
        store.get(&record.execution_id).unwrap().exit_code,
        Some(130)
    );
    assert!(store.get("../secret").is_err());
    assert!(store.get(&"f".repeat(32)).is_err());
    assert!(canonical_repo("/makevn-nonexistent-repo").is_err());
    assert!(private_directory(&fixture.0.join("linked")).is_ok());
    fs::remove_dir(fixture.0.join("linked")).unwrap();
    symlink(&fixture.0, fixture.0.join("linked")).unwrap();
    assert!(private_directory(&fixture.0.join("linked")).is_err());
}

#[test]
fn admission_contention_is_bounded_without_starting_an_execution() {
    let fixture = Fixture::new();
    let store = fixture.store();
    let admission = registry_admission(&fixture.0).unwrap();
    let start = Instant::now();
    let error = store.prepare(&fixture.params("verify")).err().unwrap();
    assert!(error.contains("admission is busy"));
    assert!(start.elapsed() < Duration::from_secs(1));
    assert!(store.list(&json!({})).unwrap().is_empty());
    drop(admission);
    assert!(store.prepare(&fixture.params("verify")).is_ok());
}
