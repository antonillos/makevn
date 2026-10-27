use super::*;
use crate::agent_test_fixture::Fixture;

fn setup(fixture: &Fixture) -> (PathBuf, PathBuf, PathBuf) {
    let home = fixture.0.join("home");
    let repo = fixture.0.join("repo");
    fs::create_dir(&home).unwrap();
    fs::create_dir(&repo).unwrap();
    fs::create_dir(repo.join(".git")).unwrap();
    (home, repo, fixture.bundle())
}

fn run_at(scope: Option<Scope>, home: &Path, repo: &Path, source: &Path) -> Result<(), String> {
    execute(
        scope,
        home,
        repo,
        &home.join(".config"),
        &home.join(".codex"),
        source,
    )
}

#[test]
fn upgrades_project_before_global_and_all_registered_clients() {
    let fixture = Fixture::new();
    let (home, repo, source) = setup(&fixture);
    let global = home.join(".codex/config.toml");
    let local = repo.join(".codex/config.toml");
    let opencode = repo.join(".opencode/opencode.jsonc");
    for path in [&global, &local] {
        install(
            Client::Codex,
            path,
            &source,
            &home.join(".agents/skills"),
            "old",
        )
        .unwrap();
        fs::write(
            path,
            "# keep\n[mcp_servers.makevn]\ncommand = 'old'\ntool_timeout_sec = 1\n",
        )
        .unwrap();
    }
    install(
        Client::OpenCode,
        &opencode,
        &source,
        &repo.join(".agents/skills"),
        "old",
    )
    .unwrap();
    fs::write(
        &opencode,
        r#"{"theme":"dark","mcp":{"makevn":{"command":["old"]}}}"#,
    )
    .unwrap();
    fs::write(source.join("makevn/new-reference.md"), "new resource").unwrap();
    run_at(None, &home, &repo, &source).unwrap();
    assert!(fs::read_to_string(&global)
        .unwrap()
        .contains("command = 'old'"));
    assert_eq!(config_status(Client::Codex, &local), "current");
    assert_eq!(config_status(Client::OpenCode, &opencode), "current");
    assert!(fs::read_to_string(&local).unwrap().contains("# keep"));
    assert!(fs::read_to_string(&opencode).unwrap().contains("dark"));
    assert!(repo
        .join(".agents/skills/makevn/new-reference.md")
        .is_file());
    assert!(!home.join(".agents/skills/makevn/new-reference.md").exists());
    run_at(Some(Scope::Global), &home, &repo, &source).unwrap();
    assert_eq!(config_status(Client::Codex, &global), "current");
    let before = fs::read(&local).unwrap();
    run_at(None, &home, &repo, &source).unwrap();
    assert_eq!(fs::read(&local).unwrap(), before);
}

#[test]
fn falls_back_to_global_without_registering_unrelated_project_clients() {
    let fixture = Fixture::new();
    let (home, repo, source) = setup(&fixture);
    fs::create_dir(repo.join(".makevn")).unwrap();
    fs::create_dir(repo.join(".codex")).unwrap();
    fs::write(repo.join(".codex/config.toml"), "model = 'keep'\n").unwrap();
    let config = home.join(".config/opencode/opencode.json");
    install(
        Client::OpenCode,
        &config,
        &source,
        &home.join(".agents/skills"),
        "old",
    )
    .unwrap();
    fs::write(source.join("makevn/new.md"), "new").unwrap();
    run_at(None, &home, &repo, &source).unwrap();
    assert!(home.join(".agents/skills/makevn/new.md").exists());
    assert!(!repo.join(".agents").exists());
    assert!(!home.join(".codex").exists());
    assert_eq!(
        fs::read_to_string(repo.join(".codex/config.toml")).unwrap(),
        "model = 'keep'\n"
    );
    fs::remove_dir(repo.join(".git")).unwrap();
    run_at(None, &home, &repo, &source).unwrap();
    assert!(run_at(Some(Scope::Project), &home, &repo, &source)
        .unwrap_err()
        .contains("Git worktree"));
}

#[test]
fn upgrades_skills_only_registration_and_rejects_missing_integration() {
    let fixture = Fixture::new();
    let (home, repo, source) = setup(&fixture);
    assert!(run_at(None, &home, &repo, &source)
        .unwrap_err()
        .contains("agent install"));
    assert!(!home.join(".agents").exists());
    let target = repo.join(".agents/skills");
    agent_transaction::apply(agent_skills::prepare(&source, &target, "old").unwrap()).unwrap();
    fs::write(source.join("makevn/new.md"), "new").unwrap();
    run_at(None, &home, &repo, &source).unwrap();
    assert!(target.join("makevn/new.md").exists());
    assert!(!repo.join(".codex").exists());
    assert!(!repo.join(".opencode").exists());
    assert!(run_at(Some(Scope::Global), &home, &repo, &source).is_err());
}

#[test]
fn conflicts_and_invalid_clients_leave_all_resources_unchanged() {
    let fixture = Fixture::new();
    let (home, repo, source) = setup(&fixture);
    let target = repo.join(".agents/skills");
    let config = repo.join(".codex/config.toml");
    install(Client::Codex, &config, &source, &target, "old").unwrap();
    let original = fs::read(&config).unwrap();
    fs::write(target.join("makevn/SKILL.md"), "local changes").unwrap();
    assert!(run_at(None, &home, &repo, &source)
        .unwrap_err()
        .contains("locally modified"));
    assert_eq!(fs::read(&config).unwrap(), original);
    assert_eq!(
        fs::read_to_string(target.join("makevn/SKILL.md")).unwrap(),
        "local changes"
    );
    fs::copy(
        source.join("makevn/SKILL.md"),
        target.join("makevn/SKILL.md"),
    )
    .unwrap();
    fs::write(source.join("makevn/new.md"), "new").unwrap();
    fs::create_dir(repo.join(".opencode")).unwrap();
    fs::write(
        repo.join(".opencode/opencode.jsonc"),
        r#"{"mcp":{"makevn":{},"servers":false}}"#,
    )
    .unwrap();
    assert!(run_at(None, &home, &repo, &source).is_err());
    assert_eq!(fs::read(&config).unwrap(), original);
    assert!(!target.join("makevn/new.md").exists());
    fs::write(&config, "key = 'private-test-value\n").unwrap();
    fs::remove_dir_all(repo.join(".opencode")).unwrap();
    let error = run_at(None, &home, &repo, &source).unwrap_err();
    assert!(!error.contains("private-test-value"));
}

#[test]
fn detects_native_opencode_and_multiple_configs_without_following_symlinks() {
    let fixture = Fixture::new();
    let (home, repo, source) = setup(&fixture);
    fs::create_dir(repo.join(".opencode")).unwrap();
    let first = repo.join(".opencode/opencode.jsonc");
    let second = repo.join("opencode.json");
    fs::write(
        &first,
        r#"{"mcp":{"servers":{"makevn":{"command":["old"]}}}}"#,
    )
    .unwrap();
    fs::write(&second, r#"{"mcp":{"makevn":{"command":["old"]}}}"#).unwrap();
    run_at(None, &home, &repo, &source).unwrap();
    for path in [&first, &second] {
        assert_eq!(config_status(Client::OpenCode, path), "current");
    }
    assert!(opencode_document(&fs::read_to_string(&first).unwrap())
        .unwrap()
        .pointer("/mcp/servers/makevn")
        .is_some());
    fs::remove_file(&second).unwrap();
    std::os::unix::fs::symlink(&first, &second).unwrap();
    assert!(run_at(None, &home, &repo, &source)
        .unwrap_err()
        .contains("symlink"));
}

#[test]
fn rejects_configuration_changed_after_preparation() {
    let fixture = Fixture::new();
    let config = fixture.0.join("config.toml");
    fs::write(&config, "[mcp_servers.makevn]\ncommand = 'old'\n").unwrap();
    let configs = [(Client::Codex, config.clone())];
    let prepared = prepare_configs(&configs).unwrap();
    let concurrent = "[mcp_servers.makevn]\ncommand = 'concurrent'\n";
    fs::write(&config, concurrent).unwrap();
    assert!(configuration_updates(prepared)
        .unwrap_err()
        .contains("Configuration changed during setup"));
    assert_eq!(fs::read_to_string(&config).unwrap(), concurrent);
}
