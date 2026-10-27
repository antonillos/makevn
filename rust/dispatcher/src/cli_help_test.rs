use super::*;

#[test]
fn every_command_has_consistent_plain_help() {
    for command in COMMANDS.iter().chain(
        [
            "agent install",
            "agent status",
            "agent upgrade",
            "profile refresh",
            "jdk current",
            "jdk list",
            "crap install-analyzer",
        ]
        .iter(),
    ) {
        let output = render_command(command, false).unwrap();
        assert!(output.starts_with("DESCRIPTION\n  "), "{command}");
        assert!(output.contains("\n\nUSAGE\n  makevn"), "{command}");
        assert!(!output.contains('\x1b'));
        if let Some(flags) = output.find("\nFLAGS\n") {
            assert!(flags < output.find("GLOBAL FLAGS\n").unwrap());
        }
        if let Some(children) = output.find("SUBCOMMANDS\n") {
            assert!(output.find("GLOBAL FLAGS\n").unwrap() < children);
        }
    }
}

#[test]
fn root_lists_all_commands_and_uses_reference_palette() {
    let plain = render_root(false);
    assert!(plain.contains("\nCOMMANDS\n"));
    assert!(!plain.contains("SUBCOMMANDS"));
    assert!(render_command("agent", false)
        .unwrap()
        .contains("\nSUBCOMMANDS\n"));
    assert!(!render_command("doctor", false)
        .unwrap()
        .contains("SUBCOMMANDS"));
    for command in COMMANDS {
        assert!(plain.contains(&format!("  {command} ")));
    }
    let colored = render_root(true);
    for code in ["1", "38;5;147", "38;5;155", "38;5;245"] {
        assert!(colored.contains(&format!("\x1b[{code}m")), "{code}");
    }
    assert!(!plain.contains('\x1b'));
}

#[test]
fn nested_help_entry_points_agree() {
    for path in [
        "agent install",
        "agent status",
        "agent upgrade",
        "profile refresh",
        "jdk current",
        "crap install-analyzer",
    ] {
        for request in [
            format!("{path} --help"),
            format!("{path} -h"),
            format!("help {path}"),
        ] {
            let args: Vec<_> = request
                .split_whitespace()
                .map(std::ffi::OsString::from)
                .collect();
            assert_eq!(requested_command(&args).unwrap().as_deref(), Some(path));
        }
    }
    let args = ["test", "--", "--help"].map(std::ffi::OsString::from);
    assert_eq!(requested_command(&args).unwrap(), None);
    let args = ["help", "unknown"].map(std::ffi::OsString::from);
    assert!(requested_command(&args).is_err());
}

#[test]
fn help_detection_preserves_normal_commands_and_global_options() {
    for request in [
        "",
        "--help",
        "help",
        "doctor",
        "test --name Example",
        "test -- --help",
    ] {
        let args: Vec<_> = request
            .split_whitespace()
            .map(std::ffi::OsString::from)
            .collect();
        assert_eq!(requested_command(&args).unwrap(), None, "{request}");
    }
    for request in [
        "--repo /tmp --compact --tail doctor --help",
        "test --name Example --help",
    ] {
        let args: Vec<_> = request
            .split_whitespace()
            .map(std::ffi::OsString::from)
            .collect();
        assert!(requested_command(&args).unwrap().is_some());
    }
    assert!(resolve_help(&[], true).unwrap().is_none());
    assert!(resolve_help(&["agent", "unknown"], true).is_err());
    assert!(render_command("unknown", false).is_none());
    assert_eq!(syntax("<CLIENT>", "", false), "<CLIENT>");
    assert!(render_command("agent install", true)
        .unwrap()
        .contains("ARGUMENTS"));
    print_mcp_help();
    print_help(false);
}
