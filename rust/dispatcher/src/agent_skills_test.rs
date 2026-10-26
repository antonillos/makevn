use super::*;
use crate::agent_test_fixture::Fixture;

#[test]
fn manages_five_skills_and_reports_missing_current_outdated_modified() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let target = fixture.0.join("skills");
    assert_eq!(status(&source, &target, "1"), "absent");
    agent_transaction::apply(prepare(&source, &target, "1").unwrap()).unwrap();
    assert!(status(&source, &target, "1").starts_with("current"));
    assert!(status(&source, &target, "2").starts_with("outdated"));
    let file = source.join("makevn/SKILL.md");
    fs::write(
        &file,
        format!("{}new content", fs::read_to_string(&file).unwrap()),
    )
    .unwrap();
    assert!(status(&source, &target, "1").starts_with("outdated"));
    agent_transaction::apply(prepare(&source, &target, "2").unwrap()).unwrap();
    assert!(status(&source, &target, "2").starts_with("current"));
    fs::write(target.join("makevn/SKILL.md"), "local edit").unwrap();
    assert!(prepare(&source, &target, "2")
        .unwrap_err()
        .contains("locally modified"));
    assert!(status(&source, &target, "2").contains("conflict"));
}

#[test]
fn refuses_unmanaged_empty_or_populated_directories_and_added_files() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let target = fixture.0.join("skills");
    fs::create_dir_all(target.join("makevn")).unwrap();
    assert!(prepare(&source, &target, "1")
        .unwrap_err()
        .contains("Unmanaged skill directory"));
    fs::write(target.join("makevn/custom.md"), "user").unwrap();
    assert!(prepare(&source, &target, "1").is_err());
    fs::remove_dir_all(&target).unwrap();
    agent_transaction::apply(prepare(&source, &target, "1").unwrap()).unwrap();
    fs::write(target.join("makevn/custom.md"), "user").unwrap();
    assert!(prepare(&source, &target, "2").is_err());
}

#[test]
fn rejects_symlinks_invalid_metadata_and_manifests() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let target = fixture.0.join("skills");
    std::os::unix::fs::symlink("SKILL.md", source.join("makevn/link")).unwrap();
    assert!(prepare(&source, &target, "1").is_err());
    fs::remove_file(source.join("makevn/link")).unwrap();
    fs::write(source.join("makevn/SKILL.md"), "invalid").unwrap();
    assert!(prepare(&source, &target, "1")
        .unwrap_err()
        .contains("metadata"));
    fs::write(
        source.join("makevn/SKILL.md"),
        "---\nname: makevn\ndescription: good\n---\n",
    )
    .unwrap();
    fs::create_dir_all(&target).unwrap();
    fs::write(target.join(MANIFEST), "{}").unwrap();
    assert!(prepare(&source, &target, "1").is_err());
    fs::write(
        target.join(MANIFEST),
        r#"{"schema":2,"version":"1","files":{}}"#,
    )
    .unwrap();
    assert!(prepare(&source, &target, "1")
        .unwrap_err()
        .contains("schema"));
}

#[test]
fn updates_remove_only_obsolete_owned_resources() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let target = fixture.0.join("skills");
    let resource = source.join("makevn/old.md");
    fs::write(&resource, "old").unwrap();
    agent_transaction::apply(prepare(&source, &target, "1").unwrap()).unwrap();
    fs::remove_file(&resource).unwrap();
    agent_transaction::apply(prepare(&source, &target, "1").unwrap()).unwrap();
    assert!(!target.join("makevn/old.md").exists());
    fs::remove_file(target.join("makevn/SKILL.md")).unwrap();
    assert!(prepare(&source, &target, "1").is_err());
}
