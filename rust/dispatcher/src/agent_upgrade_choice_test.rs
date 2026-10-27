use super::*;
use crate::agent_test_fixture::Fixture;
use std::os::unix::fs::symlink;

fn paths(fixture: &Fixture) -> SetupPaths {
    let home = fixture.0.join("home");
    let repo = fixture.0.join("repo");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(repo.join(".git")).unwrap();
    SetupPaths {
        config_home: home.join(".config"),
        codex_home: home.join(".codex"),
        home,
        repo,
        source: fixture.bundle(),
    }
}

fn register(paths: &SetupPaths, config: &Path, scope: Scope) {
    install(
        Client::OpenCode,
        config,
        &paths.source,
        &skills_target(scope, &paths.home, &paths.repo),
        "old",
    )
    .unwrap();
}

#[test]
fn linked_json_can_update_real_jsonc_destination_without_replacing_link() {
    let fixture = Fixture::new();
    let paths = paths(&fixture);
    let destination = paths.repo.join("opencode.jsonc");
    register(&paths, &destination, Scope::Project);
    fs::create_dir(paths.repo.join(".opencode")).unwrap();
    let alias = paths.repo.join(".opencode/opencode.json");
    symlink("../opencode.jsonc", &alias).unwrap();
    fs::write(
        &destination,
        r#"{"theme":"keep","mcp":{"makevn":{"command":["old"]}}}"#,
    )
    .unwrap();
    let mut output = Vec::new();
    let (scope, configs) = select(None, &paths, &mut &b"1\n"[..], &mut output).unwrap();
    assert_eq!(scope, Scope::Project);
    assert_eq!(configs, vec![(Client::OpenCode, destination.clone())]);
    finish(scope, &configs, &paths.home, &paths.repo, &paths.source).unwrap();
    assert_eq!(
        fs::read_link(&alias).unwrap(),
        PathBuf::from("../opencode.jsonc")
    );
    assert_eq!(config_status(Client::OpenCode, &destination), "current");
    assert!(fs::read_to_string(&destination).unwrap().contains("keep"));
    let prompt = String::from_utf8(output).unwrap();
    assert!(prompt.contains(&format!("{} -> {}", alias.display(), destination.display())));
    assert!(destination
        .with_file_name("opencode.jsonc.makevn.bak")
        .exists());
}

#[test]
fn selection_offers_global_and_separate_jsonc_without_touching_link_destination() {
    let fixture = Fixture::new();
    let paths = paths(&fixture);
    let linked = fixture.0.join("shared.jsonc");
    register(&paths, &linked, Scope::Project);
    let jsonc = paths.repo.join("opencode.jsonc");
    register(&paths, &jsonc, Scope::Project);
    fs::create_dir(paths.repo.join(".opencode")).unwrap();
    symlink(&linked, paths.repo.join(".opencode/opencode.json")).unwrap();
    let global = paths.config_home.join("opencode/opencode.jsonc");
    register(&paths, &global, Scope::Global);
    let before = fs::read(&linked).unwrap();
    let mut output = Vec::new();
    let (scope, configs) = select(None, &paths, &mut &b"2\n"[..], &mut output).unwrap();
    assert_eq!(configs, vec![(Client::OpenCode, jsonc.clone())]);
    finish(scope, &configs, &paths.home, &paths.repo, &paths.source).unwrap();
    assert_eq!(fs::read(&linked).unwrap(), before);
    let (_, configs) = select(None, &paths, &mut &b"4\n"[..], &mut Vec::new()).unwrap();
    assert_eq!(configs, vec![(Client::OpenCode, global)]);
    let prompt = String::from_utf8(output).unwrap();
    assert!(prompt.contains("Global integration"));
    assert!(prompt.contains("opencode.jsonc"));
}

#[test]
fn cancellation_eof_and_invalid_selections_make_no_changes() {
    let fixture = Fixture::new();
    let paths = paths(&fixture);
    let destination = fixture.0.join("shared.jsonc");
    register(&paths, &destination, Scope::Project);
    symlink(&destination, paths.repo.join("opencode.json")).unwrap();
    let before = fs::read(&destination).unwrap();
    for answer in ["", "\n", "0\n", "2\n", "bad\n"] {
        assert!(select(None, &paths, &mut answer.as_bytes(), &mut Vec::new()).is_err());
        assert_eq!(fs::read(&destination).unwrap(), before);
    }
}

#[test]
fn single_regular_registration_needs_no_input_and_explicit_scope_filters_choices() {
    let fixture = Fixture::new();
    let paths = paths(&fixture);
    let config = paths.repo.join("opencode.jsonc");
    register(&paths, &config, Scope::Project);
    let mut output = Vec::new();
    let (scope, configs) = select(None, &paths, &mut &b""[..], &mut output).unwrap();
    assert_eq!(scope, Scope::Project);
    assert_eq!(configs, vec![(Client::OpenCode, config)]);
    assert!(output.is_empty());
    let global = paths.config_home.join("opencode/opencode.jsonc");
    register(&paths, &global, Scope::Global);
    let (scope, configs) = select(Some(Scope::Global), &paths, &mut &b""[..], &mut output).unwrap();
    assert_eq!(scope, Scope::Global);
    assert_eq!(configs, vec![(Client::OpenCode, global)]);
    assert!(output.is_empty());
}

#[test]
fn detects_retargeted_links_and_deduplicates_aliases_for_all_selection() {
    let fixture = Fixture::new();
    let paths = paths(&fixture);
    let destination = paths.repo.join("opencode.jsonc");
    register(&paths, &destination, Scope::Project);
    let alias = paths.repo.join("opencode.json");
    symlink(&destination, &alias).unwrap();
    let (_, configs) = select(None, &paths, &mut &b"3\n"[..], &mut Vec::new()).unwrap();
    assert_eq!(configs.len(), 1);
    let choices = discover(None, &paths).unwrap();
    fs::remove_file(&alias).unwrap();
    let other = fixture.0.join("other.jsonc");
    fs::write(&other, "{}").unwrap();
    symlink(&other, &alias).unwrap();
    assert!(validate(&choices[1].configs[0])
        .unwrap_err()
        .contains("changed"));
}

#[test]
fn rejects_broken_links_missing_integrations_and_explicit_project_outside_git() {
    let fixture = Fixture::new();
    let mut paths = paths(&fixture);
    assert!(discover(None, &paths)
        .err()
        .unwrap()
        .contains("No existing"));
    // Existing parent links are resolved for inspection, but broken links fail clearly.
    fs::create_dir_all(&paths.config_home).unwrap();
    symlink(
        fixture.0.join("missing"),
        paths.config_home.join("opencode"),
    )
    .unwrap();
    assert!(discover(None, &paths)
        .err()
        .unwrap()
        .contains("Cannot resolve"));
    paths.repo = paths.home.clone();
    assert!(discover(Some(Scope::Project), &paths)
        .err()
        .unwrap()
        .contains("Git worktree"));
}

#[test]
fn linked_directory_can_be_confirmed_and_global_skills_only_can_be_selected() {
    let fixture = Fixture::new();
    let paths = paths(&fixture);
    let directory = fixture.0.join("shared");
    let destination = directory.join("opencode.jsonc");
    register(&paths, &destination, Scope::Project);
    symlink(&directory, paths.repo.join(".opencode")).unwrap();
    let global = skills_target(Scope::Global, &paths.home, &paths.repo);
    agent_transaction::apply(agent_skills::prepare(&paths.source, &global, "old").unwrap())
        .unwrap();
    let mut output = Vec::new();
    let (_, configs) = select(None, &paths, &mut &b"1\n"[..], &mut output).unwrap();
    assert_eq!(configs, vec![(Client::OpenCode, destination)]);
    let (scope, configs) = select(None, &paths, &mut &b"2\n"[..], &mut Vec::new()).unwrap();
    assert_eq!(scope, Scope::Global);
    assert!(configs.is_empty());
    assert!(String::from_utf8(output)
        .unwrap()
        .contains("Managed skills only"));
    fs::remove_dir_all(paths.repo.join(".git")).unwrap();
    let (scope, _) = select(None, &paths, &mut &b""[..], &mut Vec::new()).unwrap();
    assert_eq!(scope, Scope::Global);
}
