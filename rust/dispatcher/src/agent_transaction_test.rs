use super::*;
use crate::agent_test_fixture::Fixture;

#[test]
fn staging_failure_leaves_original_files_untouched_and_cleans_temporary_files() {
    let fixture = Fixture::new();
    let first = fixture.0.join("a");
    let blocker = fixture.0.join("z");
    fs::write(&first, "original").unwrap();
    fs::write(&blocker, "file").unwrap();
    let changes = Changes::from([
        (first.clone(), Some(b"changed".to_vec())),
        (blocker.join("file"), Some(vec![])),
    ]);
    assert!(apply(changes).is_err());
    assert_eq!(fs::read_to_string(&first).unwrap(), "original");
    assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 2);
}

#[test]
fn replaces_removes_and_preserves_file_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Fixture::new();
    let path = fixture.0.join("file");
    fs::write(&path, "original").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    apply(Changes::from([(path.clone(), Some(b"new".to_vec()))])).unwrap();
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    apply(Changes::from([(path.clone(), None)])).unwrap();
    assert!(!path.exists());
    assert_eq!(read(&path).unwrap(), None);
}

#[test]
fn rollback_restores_changed_and_removes_new_files() {
    let fixture = Fixture::new();
    let existing = fixture.0.join("existing");
    let new = fixture.0.join("new");
    fs::write(&existing, "replacement").unwrap();
    fs::write(&new, "new").unwrap();
    let mut transaction = Transaction {
        created_dirs: vec![],
        staged: vec![],
        replaced: Changes::from([
            (existing.clone(), Some(b"original".to_vec())),
            (new.clone(), None),
        ]),
    };
    assert!(transaction.restore().is_empty());
    assert_eq!(fs::read_to_string(existing).unwrap(), "original");
    assert!(!new.exists());
}

#[test]
fn rejects_symlink_destinations() {
    let fixture = Fixture::new();
    let path = fixture.0.join("link");
    std::os::unix::fs::symlink(fixture.0.join("missing"), &path).unwrap();
    assert!(apply(Changes::from([(path, Some(vec![]))])).is_err());
}

#[test]
fn replacement_failure_rolls_back_already_committed_files() {
    let fixture = Fixture::new();
    let existing = fixture.0.join("existing");
    let new = fixture.0.join("new");
    fs::write(&existing, "original").unwrap();
    let mut transaction = Transaction {
        created_dirs: vec![],
        staged: vec![],
        replaced: Changes::new(),
    };
    let first = transaction.stage(&existing, b"replacement").unwrap();
    let second = transaction.stage(&new, b"new").unwrap();
    let result = transaction.commit(vec![
        (existing.clone(), Some(b"original".to_vec()), Some(first)),
        (new.clone(), None, Some(second)),
        (
            fixture.0.join("fail"),
            None,
            Some(fixture.0.join("missing-stage")),
        ),
    ]);
    assert!(result.unwrap_err().contains("rollback errors: []"));
    assert_eq!(fs::read_to_string(existing).unwrap(), "original");
    assert!(!new.exists());
}
