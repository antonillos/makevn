use super::*;
use crate::agent_test_fixture::Fixture;
use std::os::unix::fs::PermissionsExt;

#[test]
fn parses_clients_scopes_and_rejects_ambiguous_status() {
    for client in ["opencode", "codex"] {
        for scope in ["global", "project"] {
            for action in ["install", "status"] {
                let args: Vec<_> = [action, client, "--scope", scope]
                    .map(OsString::from)
                    .into();
                assert_eq!(parse(&args).unwrap().status, action == "status");
            }
        }
    }
    for args in [
        vec!["status", "codex"],
        vec!["install", "other"],
        vec!["install", "codex", "--scope", "other"],
        vec!["install", "codex", "--bad", "global"],
        vec!["bad", "codex"],
        vec![],
    ] {
        assert!(parse(&args.into_iter().map(OsString::from).collect::<Vec<_>>()).is_err());
    }
}

#[test]
fn client_scope_paths_preserve_existing_opencode_selection() {
    let fixture = Fixture::new();
    let root = &fixture.0;
    let global = root.join("global/config");
    for client in [Client::OpenCode, Client::Codex] {
        for scope in [Scope::Global, Scope::Project] {
            let request = Request {
                client,
                scope: Some(scope),
                status: false,
            };
            let (actual, path) = select_config(&request, root, &global).unwrap();
            assert_eq!(actual, scope);
            if scope == Scope::Global {
                assert_eq!(path, global);
            } else {
                assert!(path.starts_with(root));
                assert_ne!(path, global);
            }
        }
    }
    let request = Request {
        client: Client::Codex,
        scope: None,
        status: false,
    };
    assert_eq!(
        select_config(&request, root, &global).unwrap(),
        (Scope::Global, global)
    );
    assert!(local_configs(root).is_empty());
    fs::create_dir(root.join(".opencode")).unwrap();
    for name in ["opencode.jsonc", "opencode.json"] {
        fs::write(root.join(".opencode").join(name), "{}").unwrap();
    }
    assert_eq!(local_configs(root).len(), 2);
    assert_eq!(
        opencode_config(&root.join(".opencode")),
        root.join(".opencode/opencode.jsonc")
    );
    assert_eq!(
        select_config(
            &Request {
                client: Client::OpenCode,
                scope: Some(Scope::Project),
                status: false
            },
            root,
            Path::new("global")
        )
        .unwrap()
        .1,
        root.join(".opencode/opencode.jsonc")
    );
}

#[test]
fn installs_both_clients_idempotently_and_preserves_permissions_and_backups() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let target = fixture.0.join("skills");
    let originals = [
        (Client::OpenCode, "opencode.jsonc", "{ // comment\n\"theme\":\"dark\",\"permission\":{\"skill\":{\"makevn\":\"deny\"}},\"mcp\":{\"other\":{\"enabled\":true}},}"),
        (Client::Codex, "config.toml", "# comment\nmodel = 'example'\n[mcp_servers.other]\ncommand = 'other'\n[permissions]\nmode = 'strict'\n"),
    ];
    for (client, name, original) in originals {
        let config = fixture.0.join(name);
        fs::write(&config, original).unwrap();
        install(client, &config, &source, &target, "1").unwrap();
        let first = fs::read(&config).unwrap();
        let backup = PathBuf::from(format!("{}.makevn.bak", config.display()));
        assert_eq!(fs::read_to_string(&backup).unwrap(), original);
        assert_eq!(
            fs::metadata(&backup).unwrap().permissions().mode() & 0o777,
            0o600
        );
        install(client, &config, &source, &target, "1").unwrap();
        assert_eq!(fs::read(&config).unwrap(), first);
        assert_eq!(fs::read_to_string(&backup).unwrap(), original);
        assert_eq!(
            fs::metadata(&backup).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(config_status(client, &config), "current");
        let text = fs::read_to_string(&config).unwrap();
        if client == Client::OpenCode {
            let document = opencode_document(&text).unwrap();
            assert_eq!(document["permission"]["skill"]["makevn"], "deny");
            assert_eq!(document["mcp"]["other"]["enabled"], true);
            assert_eq!(document["mcp"]["makevn"]["timeout"], 1800000);
        } else {
            assert!(text.contains("# comment"));
            assert!(text.contains("mode = 'strict'"));
            assert!(text.contains("command = 'other'"));
        }
    }
}

#[test]
fn preflight_failures_do_not_change_configuration_or_skills() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let target = fixture.0.join("skills");
    let config = fixture.0.join("config.toml");
    fs::write(&config, "invalid[").unwrap();
    assert!(install(Client::Codex, &config, &source, &target, "1").is_err());
    assert!(!target.exists());
    assert_eq!(fs::read_to_string(&config).unwrap(), "invalid[");
    fs::write(&config, "").unwrap();
    install(Client::Codex, &config, &source, &target, "1").unwrap();
    fs::write(target.join("makevn/SKILL.md"), "local").unwrap();
    let before = fs::read(&config).unwrap();
    assert!(install(Client::Codex, &config, &source, &target, "2").is_err());
    assert_eq!(fs::read(&config).unwrap(), before);
}

#[test]
fn setup_lock_and_invalid_configurations_fail_with_diagnostics() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let target = fixture.0.join("skills");
    fs::create_dir(&target).unwrap();
    fs::write(target.join(".makevn-setup.lock"), "busy").unwrap();
    let config = fixture.0.join("config.toml");
    assert!(install(Client::Codex, &config, &source, &target, "1")
        .unwrap_err()
        .contains("lock"));
    assert!(!config.exists());
    for text in ["mcp_servers = false", "[mcp_servers]\nmakevn = false"] {
        assert!(configure_codex(text).is_err());
    }
    assert!(opencode_document("{invalid}").is_err());
    assert!(configure(Client::OpenCode, "[]", &config).is_err());
    assert!(configure(Client::OpenCode, r#"{"mcp":false}"#, &config).is_err());
    assert!(config_status(Client::Codex, &config).contains("absent"));
    fs::write(&config, "invalid[").unwrap();
    assert!(config_status(Client::Codex, &config).starts_with("invalid"));
}

#[test]
fn executes_registration_and_read_only_status_in_both_scopes() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let home = fixture.0.join("home");
    let repo = fixture.0.join("repo");
    fs::create_dir(&home).unwrap();
    fs::create_dir(&repo).unwrap();
    fs::create_dir(repo.join(".git")).unwrap();
    for scope in [Scope::Global, Scope::Project] {
        for client in [Client::OpenCode, Client::Codex] {
            for status in [true, false, true] {
                execute(
                    &Request {
                        client,
                        scope: Some(scope),
                        status,
                    },
                    &home,
                    &repo,
                    &home.join(".config"),
                    &home.join(".codex"),
                    &source,
                )
                .unwrap();
            }
        }
    }
}

#[test]
fn interactive_selection_keeps_all_configs_and_checks_input() {
    let fixture = Fixture::new();
    let repo = &fixture.0;
    let global = repo.join("global");
    let mut output = vec![];
    assert_eq!(
        choose_opencode(repo, &global, &mut &b""[..], &mut output).unwrap(),
        (Scope::Global, global.clone())
    );
    fs::create_dir(repo.join(".opencode")).unwrap();
    fs::write(repo.join(".opencode/opencode.jsonc"), "{}").unwrap();
    fs::write(repo.join(".opencode/opencode.json"), "{}").unwrap();
    for (answer, expected) in [
        ("\n", repo.join(".opencode/opencode.jsonc")),
        ("2\n", repo.join(".opencode/opencode.json")),
        ("3\n", global.clone()),
    ] {
        assert_eq!(
            choose_opencode(repo, &global, &mut answer.as_bytes(), &mut output)
                .unwrap()
                .1,
            expected
        );
    }
    for answer in ["0\n", "4\n", "invalid\n"] {
        assert!(choose_opencode(repo, &global, &mut answer.as_bytes(), &mut output).is_err());
    }
    let prompt = String::from_utf8(output).unwrap();
    assert!(prompt.contains("opencode.jsonc"));
    assert!(prompt.contains("opencode.json"));
    assert!(prompt.contains("Global config"));
}

#[test]
fn preserves_native_opencode_v2_server_layout_and_permissions() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let target = fixture.0.join("skills");
    let config = fixture.0.join("opencode.jsonc");
    fs::write(&config, r#"{"permissions":[{"action":"skill","resource":"makevn","effect":"deny"}],"mcp":{"servers":{"other":{"type":"local","command":["other"]}},"timeout":{"execution":42}}}"#).unwrap();
    install(Client::OpenCode, &config, &source, &target, "1").unwrap();
    let document = opencode_document(&fs::read_to_string(&config).unwrap()).unwrap();
    assert_eq!(
        document["mcp"]["servers"]["makevn"]["timeout"]["execution"],
        1800000
    );
    assert_eq!(document["mcp"]["servers"]["makevn"]["disabled"], false);
    assert_eq!(
        document["mcp"]["servers"]["other"]["command"],
        serde_json::json!(["other"])
    );
    assert_eq!(document["mcp"]["timeout"]["execution"], 42);
    assert_eq!(document["permissions"][0]["effect"], "deny");
    assert!(document["mcp"].get("makevn").is_none());
    assert_eq!(config_status(Client::OpenCode, &config), "current");
    assert!(configure(Client::OpenCode, r#"{"mcp":{"servers":false}}"#, &config).is_err());
}

#[test]
fn invalid_toml_diagnostics_do_not_echo_configuration_values() {
    let error = configure_codex("[provider]\nkey = 'private-test-value\n").unwrap_err();
    assert!(error.contains("Invalid Codex TOML"));
    assert!(!error.contains("private-test-value"));
}

#[test]
fn inline_codex_servers_support_install_status_and_idempotence() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let target = fixture.0.join("skills");
    let config = fixture.0.join("config.toml");
    for original in [
        "mcp_servers = { other = { command = 'other' } }\n",
        "mcp_servers = { other = { command = 'other' }, makevn = { url = 'https://example.test', args = ['old'], custom = true } }\n",
    ] {
        fs::write(&config, original).unwrap();
        assert!(config_status(Client::Codex, &config).contains("outdated"));
        assert_eq!(fs::read_to_string(&config).unwrap(), original);
        install(Client::Codex, &config, &source, &target, "1").unwrap();
        let updated = fs::read_to_string(&config).unwrap();
        let document = updated.parse::<DocumentMut>().unwrap();
        assert_eq!(document["mcp_servers"]["other"]["command"].as_str(), Some("other"));
        let server = &document["mcp_servers"]["makevn"];
        assert_eq!(server["command"].as_str(), Some("makevn-mcp"));
        assert!(server.get("url").is_none());
        assert!(server.get("args").is_none());
        if original.contains("custom") {
            assert_eq!(server["custom"].as_bool(), Some(true));
        }
        assert_eq!(config_status(Client::Codex, &config), "current");
        install(Client::Codex, &config, &source, &target, "1").unwrap();
        assert_eq!(fs::read_to_string(&config).unwrap(), updated);
    }
}

#[test]
fn project_scope_rejects_non_git_directories_without_writes() {
    let fixture = Fixture::new();
    let source = fixture.bundle();
    let home = fixture.0.join("home");
    fs::create_dir(&home).unwrap();
    for client in [Client::OpenCode, Client::Codex] {
        for status in [false, true] {
            let error = execute(
                &Request {
                    client,
                    scope: Some(Scope::Project),
                    status,
                },
                &home,
                &home,
                &home.join(".config"),
                &home.join(".codex"),
                &source,
            )
            .unwrap_err();
            assert!(error.contains("Project scope requires a Git worktree"));
            assert_eq!(fs::read_dir(&home).unwrap().count(), 0);
        }
    }
    // Linked worktrees use a .git file rather than a directory.
    fs::write(home.join(".git"), "gitdir: /example/worktrees/project\n").unwrap();
    execute(
        &Request {
            client: Client::Codex,
            scope: Some(Scope::Project),
            status: false,
        },
        &home,
        &home,
        &home.join(".config"),
        &home.join(".codex"),
        &source,
    )
    .unwrap();
    assert!(home.join(".codex/config.toml").is_file());
}
