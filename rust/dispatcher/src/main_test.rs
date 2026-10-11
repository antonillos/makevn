use super::{
    clear_tail_rows, command_help, command_suggestion_suffix, command_supports_frontend_loader,
    dashboard_hint, detect_local_opencode_configs, dim_text, exit_code_from_status,
    format_failure_summary, format_resource_sample_cpu, format_resource_sample_ram,
    insert_backend_option, install_opencode_agent_at, install_root, install_root_with_override,
    parse_invocation, parse_mcp_invocation, print_command_help, print_final_dashboard,
    read_backend_metadata, read_failure_hint, register_signal_flag, spinner_hint,
    spinner_resource_suffix, split_command_segments, strip_frontend_tail_flag,
    strip_jsonc_comments, summary_from_backend_metadata, tail_command_help, tail_status_lines,
    validate_maven_passthrough_args, Action, BackendDetailFile, BackendInvocation, BackendMetadata,
    CommandSummary, InputEvent, McpAction, ResourceHistory, ResourceSample, ResourceSampler,
    SpinnerRenderer, TtyModeGuard,
};
use std::env;
use std::ffi::OsString;
use std::fs;
use std::fs::File;
use std::io::Write;
use std::os::fd::FromRawFd;
#[cfg(unix)]
use std::os::unix::fs::symlink;
use std::path::Path;
use std::process;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub(super) static ENV_LOCK: Mutex<()> = Mutex::new(());

fn format_resource_sample(sample: &ResourceSample, history: &ResourceHistory) -> String {
    format!(
        "{} | {}",
        format_resource_sample_cpu(sample, history),
        format_resource_sample_ram(sample, history)
    )
}

#[test]
fn spinner_resource_suffix_preserves_hint_with_and_without_metrics() {
    assert_eq!(spinner_resource_suffix("", "interrupt"), "interrupt");
    assert!(spinner_resource_suffix("CPU 10%", "interrupt").contains("CPU 10%"));
    assert!(spinner_resource_suffix("CPU 10%", "interrupt").ends_with("interrupt"));
}

#[test]
fn resource_history_only_records_new_sample_revisions() {
    let mut history = ResourceHistory::new();
    let sample = ResourceSample {
        cpu_percent: 12.0,
        rss_kb: 64,
    };
    assert_eq!(history.sync_sample(0, 0, Some(&sample)), 0);
    assert!(history.cpu_percent.is_empty());
    assert_eq!(history.sync_sample(0, 1, Some(&sample)), 1);
    assert_eq!(history.cpu_percent, vec![Some(12.0)]);
    assert_eq!(history.rss_kb, vec![Some(64)]);
    assert_eq!(history.sync_sample(1, 2, None), 2);
    assert_eq!(history.cpu_percent, vec![Some(12.0)]);
}

#[test]
fn spinner_renderer_handles_tty_input_and_dashboard_lifecycle() {
    let mut master_fd = -1;
    let mut slave_fd = -1;
    let rc = unsafe {
        libc::openpty(
            &mut master_fd,
            &mut slave_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(rc, 0, "openpty failed: {}", std::io::Error::last_os_error());
    let mut master = unsafe { File::from_raw_fd(master_fd) };
    let tty = unsafe { File::from_raw_fd(slave_fd) };
    let tty_guard = TtyModeGuard::new(&tty).unwrap();
    let mut renderer = SpinnerRenderer {
        tty,
        tty_guard: Some(tty_guard),
        paused: false,
        frame: 0,
        frame_interval: Duration::ZERO,
        next_frame_at: Instant::now(),
        second_escape_deadline: None,
        resource_sampler: ResourceSampler::new(),
        resource_history: ResourceHistory::new(),
        resource_history_revision: 0,
        cpu_visual_load: 0.0,
        ram_visual_load: 0.0,
        resource_visual_load: 0.0,
        rendered_block_line_widths: Vec::new(),
    };

    renderer.configure_resource_source(
        "docker-up",
        Some(std::path::PathBuf::from("/nonexistent/makevn.resources")),
    );
    assert!(renderer.resource_history.cpu_percent.is_empty());
    renderer.configure_resource_source("verify", None);
    renderer.configure_resource_source("verify", None);

    master.write_all(b"tT+-x\x1b\x1b").unwrap();
    assert!(matches!(
        renderer.poll_input().unwrap(),
        InputEvent::ToggleTail
    ));
    assert!(matches!(
        renderer.poll_input().unwrap(),
        InputEvent::ToggleTail
    ));
    assert!(matches!(
        renderer.poll_input().unwrap(),
        InputEvent::IncreaseLines
    ));
    assert!(matches!(
        renderer.poll_input().unwrap(),
        InputEvent::DecreaseLines
    ));
    assert!(matches!(renderer.poll_input().unwrap(), InputEvent::None));
    assert!(matches!(renderer.poll_input().unwrap(), InputEvent::None));
    assert!(matches!(
        renderer.poll_input().unwrap(),
        InputEvent::Interrupt
    ));

    assert!(renderer
        .frame_line_with_hint(0, "interrupt")
        .unwrap()
        .contains("interrupt"));
    renderer.resource_sampler.sample_revision = 1;
    let sample = ResourceSample {
        cpu_percent: 10.0,
        rss_kb: 32,
    };
    renderer.sync_resource_history(Some(&sample));
    assert_eq!(renderer.resource_history.cpu_percent, vec![Some(10.0)]);
    renderer.sync_resource_history(Some(&sample));
    assert_eq!(renderer.resource_history.cpu_percent, vec![Some(10.0)]);

    let metadata = BackendMetadata {
        command: "verify".into(),
        repo: "repo".into(),
        cwd: "repo".into(),
        log_path: "log".into(),
        relative_log_path: "log".into(),
        command_display: "verify".into(),
        title: "Verify".into(),
        context: None,
    };
    renderer
        .render_dashboard(0, Duration::ZERO, &[], &[], &metadata, "interrupt")
        .unwrap();
    assert!(!renderer.rendered_block_line_widths.is_empty());
    renderer.clear_dynamic_block().unwrap();
    assert!(renderer.rendered_block_line_widths.is_empty());
    renderer.clear_dynamic_block().unwrap();
    renderer.rendered_block_line_widths.push(1000);
    renderer.clear_dynamic_block().unwrap();

    renderer.resource_sampler.last_sample_at = Some(Instant::now());
    renderer.resource_sampler.last_sample = Some(sample);
    renderer.next_frame_at = Instant::now() + Duration::from_millis(1);
    assert!(renderer
        .frame_line_with_hint(1, "interrupt")
        .unwrap()
        .contains("interrupt"));
    renderer.render_frame_with_hint(1, "interrupt").unwrap();
    renderer
        .render_dashboard(1, Duration::ZERO, &[], &[], &metadata, "interrupt")
        .unwrap();

    let original_tty = std::mem::replace(&mut renderer.tty, File::open("/dev/null").unwrap());
    assert!(matches!(renderer.poll_input().unwrap(), InputEvent::None));
    renderer.tty = File::options().write(true).open("/dev/null").unwrap();
    assert!(renderer.poll_input().is_err());
    renderer.tty = original_tty;
}

#[test]
fn known_command_help_can_be_printed() {
    print_command_help("verify");
}

#[test]
fn clear_tail_rows_erases_each_physical_row() {
    let mut output = Vec::new();
    clear_tail_rows(&mut output, 2).unwrap();
    assert_eq!(output, b"\x1b[2A\r\x1b[2K\n\r\x1b[2K\n\r\x1b[2K\x1b[2A\r");
}

#[test]
fn tail_command_help_covers_all_interactive_commands() {
    for command in [
        "docker-up",
        "docker-down",
        "docker-ps",
        "docker-stats",
        "karate-docker-up",
        "karate-docker-down",
    ] {
        let (usage, description, options) = tail_command_help(command, "description").unwrap();
        assert!(usage.contains(command));
        assert_eq!(description, "description");
        assert_eq!(options.len(), 1);
    }
    assert!(tail_command_help("verify", "description").is_none());
}

#[test]
fn strips_jsonc_comments_without_changing_strings_or_unicode() {
    let source = "{\"url\":\"https://example.test/a//b\",// line\n\"text\":\"🦀 \\\"/*keep*/\\\"\",/* block */\"name\":\"José\"}";
    let expected = "{\"url\":\"https://example.test/a//b\",\n\"text\":\"🦀 \\\"/*keep*/\\\"\",\"name\":\"José\"}";

    assert_eq!(strip_jsonc_comments(source), expected);
}

#[test]
fn strips_jsonc_comments_at_eof_and_preserves_unterminated_strings() {
    assert_eq!(strip_jsonc_comments("{}// trailing"), "{}");
    assert_eq!(strip_jsonc_comments("{}/* trailing"), "{}");
    assert_eq!(
        strip_jsonc_comments("{\"key\":\"a\\\"//"),
        "{\"key\":\"a\\\"//"
    );
    assert_eq!(strip_jsonc_comments("/"), "/");
}

#[test]
fn maven_passthrough_accepts_option_values_and_separator() {
    let command = OsString::from("verify");
    assert!(validate_maven_passthrough_args(
        &command,
        &[
            OsString::from("--tail"),
            OsString::from("-f"),
            OsString::from("pom.xml"),
            OsString::from("--"),
            OsString::from("custom-goal"),
        ],
    )
    .is_ok());
}

#[test]
fn maven_passthrough_rejects_bare_commands_before_separator() {
    let command = OsString::from("verify");
    let error =
        validate_maven_passthrough_args(&command, &[OsString::from("verity-ut")]).unwrap_err();
    assert!(error.contains("Extra Maven arguments for verify must follow '--'"));
    assert!(error.contains("Did you mean 'verify-ut'?"));
}

#[test]
fn install_root_honors_explicit_environment_override() {
    let _guard = ENV_LOCK.lock().unwrap();
    let original = env::var_os("MAKEVN_INSTALL_ROOT");
    env::set_var("MAKEVN_INSTALL_ROOT", "/tmp/makevn-explicit-root");
    let root = install_root(Path::new("/missing/makevn")).unwrap();
    match original {
        Some(value) => env::set_var("MAKEVN_INSTALL_ROOT", value),
        None => env::remove_var("MAKEVN_INSTALL_ROOT"),
    }
    assert_eq!(root, Path::new("/tmp/makevn-explicit-root"));
}

#[cfg(unix)]
#[test]
fn signal_handlers_register_in_isolated_process() {
    const CHILD_MARKER: &str = "MAKEVN_SIGNAL_REGISTRATION_TEST_CHILD";
    if env::var_os(CHILD_MARKER).is_some() {
        register_signal_flag(&Arc::new(AtomicBool::new(false))).unwrap();
        return;
    }

    let output = process::Command::new(env::current_exe().unwrap())
        .args([
            "--exact",
            "tests::signal_handlers_register_in_isolated_process",
        ])
        .env(CHILD_MARKER, "1")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "isolated signal registration failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn resource_sampler_skips_zero_pid_and_reuses_recent_sample() {
    let mut sampler = ResourceSampler::new();
    assert!(sampler.sample(0).unwrap().is_none());
    assert_eq!(sampler.revision(), 0);

    let cached = ResourceSample {
        cpu_percent: 12.5,
        rss_kb: 2048,
    };
    sampler.last_pid = Some(u32::MAX);
    sampler.last_sample_at = Some(std::time::Instant::now());
    sampler.last_sample = Some(cached);
    let sample = sampler.sample(u32::MAX).unwrap().unwrap();
    assert_eq!(sample.cpu_percent, cached.cpu_percent);
    assert_eq!(sample.rss_kb, cached.rss_kb);
    assert_eq!(sampler.revision(), 0);
}

#[test]
fn final_dashboard_prints_success_and_failure() {
    print_final_dashboard(Duration::from_secs(1), &[], true).unwrap();
    print_final_dashboard(Duration::from_secs(1), &[], false).unwrap();
}

#[test]
fn detail_file_reads_nonempty_lines_and_handles_absence() {
    let detail = BackendDetailFile::new().unwrap();
    assert!(detail.read_lines().is_empty());
    fs::write(detail.path(), "first\n\nsecond\n").unwrap();
    assert_eq!(detail.read_lines(), vec!["first", "second"]);
    detail.clear();
    assert!(detail.read_lines().is_empty());
}

#[test]
fn suggests_only_known_misspellings() {
    assert_eq!(
        command_suggestion_suffix(&OsString::from("verity-ut")),
        " Did you mean 'verify-ut'?"
    );
    assert_eq!(
        command_suggestion_suffix(&OsString::from("verity-it")),
        " Did you mean 'verify-it'?"
    );
    assert!(command_suggestion_suffix(&OsString::from("verify")).is_empty());
}

#[test]
fn failure_summary_handles_optional_details() {
    assert_eq!(
        format_failure_summary(2, None, None),
        " exit 2 | check the log"
    );
    assert_eq!(
        format_failure_summary(1, Some("3s"), Some("")),
        " exit 1 | 3s | check the log"
    );
    assert_eq!(
        format_failure_summary(7, Some("2s"), Some("Maven failed")),
        " exit 7 | 2s | Maven failed"
    );
}

#[test]
fn failure_hint_reads_first_error_line() {
    assert_eq!(read_failure_hint(None), None);
    assert_eq!(
        read_failure_hint(Some("/nonexistent/makevn-crap-test.log")),
        None
    );
    let path = env::temp_dir().join(format!("makevn-failure-hint-{}", process::id()));
    fs::write(
        &path,
        "info\n  Error: first problem\nError: second problem\n",
    )
    .unwrap();
    assert_eq!(
        read_failure_hint(path.to_str()),
        Some(String::from("first problem"))
    );
    fs::write(&path, "no error here\n").unwrap();
    assert_eq!(read_failure_hint(path.to_str()), None);
    fs::remove_file(path).unwrap();
}

#[test]
fn failure_hint_suggests_docker_runtime_recovery() {
    let path = env::temp_dir().join(format!("makevn-docker-hint-{}", process::id()));
    fs::write(&path, "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n").unwrap();
    let hint = read_failure_hint(path.to_str()).unwrap();
    assert!(hint.contains("colima start"));
    assert!(hint.contains("docker info"));
    fs::remove_file(path).unwrap();
}

#[test]
fn non_loader_summary_keeps_backend_log_path_for_recovery_hints() {
    let metadata = super::BackendMetadata {
        command: String::from("docker-up"),
        repo: String::from("/repo"),
        cwd: String::from("/repo"),
        log_path: String::from("/repo/.makevn/logs/docker-up.log"),
        relative_log_path: String::from(".makevn/logs/docker-up.log"),
        command_display: String::from("makevn docker-up"),
        title: String::from("docker-up"),
        context: None,
    };
    let summary = summary_from_backend_metadata(1, String::from("0s"), "fallback", Some(&metadata));
    assert_eq!(
        summary.log_path.as_deref(),
        Some(metadata.log_path.as_str())
    );
    assert_eq!(
        summary.relative_log_path.as_deref(),
        Some(metadata.relative_log_path.as_str())
    );
}

#[test]
fn exit_status_preserves_code_and_interrupt() {
    #[cfg(unix)]
    let shell = "/bin/sh";
    #[cfg(not(unix))]
    let shell = "sh";

    let success = process::Command::new(shell)
        .arg("-c")
        .arg("exit 0")
        .status()
        .unwrap();
    let failed = process::Command::new(shell)
        .arg("-c")
        .arg("exit 7")
        .status()
        .unwrap();
    assert_eq!(exit_code_from_status(success, false), 0);
    assert_eq!(exit_code_from_status(failed, false), 7);
    assert_eq!(exit_code_from_status(success, true), 130);
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(
            exit_code_from_status(process::ExitStatus::from_raw(libc::SIGTERM), false),
            130
        );
        assert_eq!(
            exit_code_from_status(process::ExitStatus::from_raw(libc::SIGKILL), false),
            1
        );
    }
}

fn current_repo_root() -> OsString {
    super::resolve_repo_root(None).unwrap().into_os_string()
}

#[test]
fn derives_install_root_from_binary_location() {
    let root = install_root_with_override(Path::new("/tmp/makevn/bin/makevn"), None).unwrap();
    assert_eq!(root, Path::new("/tmp/makevn"));
}

#[test]
fn prefers_install_root_from_environment() {
    let root = install_root_with_override(
        Path::new("/tmp/makevn/bin/makevn"),
        Some(OsString::from("/worktree/repo")),
    )
    .unwrap();
    assert_eq!(root, Path::new("/worktree/repo"));
}

#[test]
fn install_root_prefers_current_executable_runtime_over_path() {
    let _guard = ENV_LOCK.lock().unwrap();
    let unique_suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let work_dir = env::temp_dir().join(format!(
        "makevn-install-root-test-{}-{unique_suffix}",
        process::id()
    ));
    let current_root = work_dir.join("current");
    let path_root = work_dir.join("from-path");
    let current_bin = current_root.join("bin/makevn");
    let path_bin = path_root.join("bin/makevn");

    fs::create_dir_all(current_root.join("bin")).unwrap();
    fs::create_dir_all(current_root.join("libexec/makevn")).unwrap();
    fs::create_dir_all(path_root.join("bin")).unwrap();
    fs::create_dir_all(path_root.join("libexec/makevn")).unwrap();
    fs::write(&current_bin, b"").unwrap();
    fs::write(current_root.join("libexec/makevn/backend.sh"), b"").unwrap();
    fs::write(&path_bin, b"").unwrap();
    fs::write(path_root.join("libexec/makevn/backend.sh"), b"").unwrap();

    let original_path = env::var_os("PATH");
    let original_install_root = env::var_os("MAKEVN_INSTALL_ROOT");
    env::remove_var("MAKEVN_INSTALL_ROOT");
    env::set_var("PATH", path_root.join("bin"));

    let root = install_root(&current_bin).unwrap();
    let expected_root = fs::canonicalize(&current_root).unwrap();

    match original_path {
        Some(path) => env::set_var("PATH", path),
        None => env::remove_var("PATH"),
    }
    match original_install_root {
        Some(root) => env::set_var("MAKEVN_INSTALL_ROOT", root),
        None => env::remove_var("MAKEVN_INSTALL_ROOT"),
    }
    fs::remove_dir_all(work_dir).unwrap();

    assert_eq!(root, expected_root);
}

#[test]
fn install_root_falls_back_to_path_runtime() {
    let _guard = ENV_LOCK.lock().unwrap();
    let unique_suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let work_dir = env::temp_dir().join(format!(
        "makevn-install-path-test-{}-{unique_suffix}",
        process::id()
    ));
    let path_root = work_dir.join("from-path");
    fs::create_dir_all(path_root.join("bin")).unwrap();
    fs::create_dir_all(path_root.join("libexec/makevn")).unwrap();
    fs::write(path_root.join("bin/makevn"), b"").unwrap();
    fs::write(path_root.join("libexec/makevn/backend.sh"), b"").unwrap();

    let original_path = env::var_os("PATH");
    let original_install_root = env::var_os("MAKEVN_INSTALL_ROOT");
    env::remove_var("MAKEVN_INSTALL_ROOT");
    env::set_var("PATH", path_root.join("bin"));
    let root = install_root(&work_dir.join("missing/bin/makevn")).unwrap();
    match original_path {
        Some(path) => env::set_var("PATH", path),
        None => env::remove_var("PATH"),
    }
    match original_install_root {
        Some(value) => env::set_var("MAKEVN_INSTALL_ROOT", value),
        None => env::remove_var("MAKEVN_INSTALL_ROOT"),
    }
    assert_eq!(root, fs::canonicalize(&path_root).unwrap());
    fs::remove_dir_all(work_dir).unwrap();
}

#[cfg(unix)]
#[test]
fn derives_install_root_from_resolved_binary_symlink() {
    let unique_suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let work_dir = env::temp_dir().join(format!(
        "makevn-symlink-test-{}-{unique_suffix}",
        process::id()
    ));
    let cellar_bin = work_dir.join("Cellar/makevn/0.1.1/bin");
    let prefix_bin = work_dir.join("bin");
    fs::create_dir_all(&cellar_bin).unwrap();
    fs::create_dir_all(&prefix_bin).unwrap();

    let real_binary = cellar_bin.join("makevn");
    fs::write(&real_binary, b"").unwrap();
    let linked_binary = prefix_bin.join("makevn");
    symlink(&real_binary, &linked_binary).unwrap();

    let root = install_root_with_override(&linked_binary, None).unwrap();
    assert_eq!(
        root,
        fs::canonicalize(work_dir.join("Cellar/makevn/0.1.1")).unwrap()
    );

    fs::remove_dir_all(work_dir).unwrap();
}

#[test]
fn parses_version_without_backend_dispatch() {
    let action = parse_invocation(vec![OsString::from("--version")]).unwrap();
    assert_eq!(action, Action::PrintVersion);
}

#[test]
fn parses_opencode_agent_install_without_backend_dispatch() {
    let action = parse_invocation(vec![
        OsString::from("agent"),
        OsString::from("install"),
        OsString::from("opencode"),
    ])
    .unwrap();
    assert_eq!(action, Action::InstallOpenCodeAgent);
}

#[test]
fn installs_opencode_agent_idempotently_and_preserves_other_entries() {
    let unique_suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let work_dir = env::temp_dir().join(format!(
        "makevn-opencode-agent-test-{}-{unique_suffix}",
        process::id()
    ));
    fs::create_dir_all(&work_dir).unwrap();
    let config_path = work_dir.join("opencode.jsonc");
    fs::write(
        &config_path,
        "{\n  // existing config\n  \"theme\": \"dark\",\n  \"mcp\": {\"other\": {\"enabled\": true}}\n}\n",
    )
    .unwrap();

    assert_eq!(install_opencode_agent_at(&work_dir).unwrap(), config_path);
    let backup = fs::read_to_string(work_dir.join("opencode.jsonc.makevn.bak")).unwrap();
    assert_eq!(install_opencode_agent_at(&work_dir).unwrap(), config_path);

    let config: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&config_path).unwrap()).unwrap();
    assert_eq!(config["theme"], "dark");
    assert_eq!(config["mcp"]["other"]["enabled"], true);
    assert_eq!(
        config["mcp"]["makevn"]["command"],
        serde_json::json!(["makevn-mcp"])
    );
    assert_eq!(config["mcp"]["makevn"]["timeout"], 900000);
    assert!(work_dir.join("opencode.jsonc.makevn.bak").is_file());
    assert!(backup.contains("// existing config"));
    assert_eq!(
        fs::read_to_string(work_dir.join("opencode.jsonc.makevn.bak")).unwrap(),
        backup
    );

    fs::remove_dir_all(work_dir).unwrap();
}

#[test]
fn detects_all_existing_project_opencode_configs() {
    let unique_suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let work_dir = env::temp_dir().join(format!(
        "makevn-local-opencode-test-{}-{unique_suffix}",
        process::id()
    ));
    let local_config = work_dir.join(".opencode/opencode.jsonc");
    let local_json_config = work_dir.join(".opencode/opencode.json");
    fs::create_dir_all(local_config.parent().unwrap()).unwrap();
    fs::write(&local_config, "{}\n").unwrap();
    fs::write(&local_json_config, "{}\n").unwrap();

    assert_eq!(
        detect_local_opencode_configs(&work_dir),
        vec![local_config, local_json_config]
    );

    fs::remove_dir_all(work_dir).unwrap();
}

#[test]
fn preserves_global_help_dispatch() {
    let action = parse_invocation(vec![OsString::from("--help")]).unwrap();
    assert_eq!(action, Action::PrintHelp { with_header: false });
}

#[test]
fn parses_mcp_help_without_starting_server() {
    let action = parse_mcp_invocation(vec![OsString::from("--help")]).unwrap();
    assert_eq!(action, McpAction::PrintHelp);
}

#[test]
fn parses_mcp_version_without_starting_server() {
    let action = parse_mcp_invocation(vec![OsString::from("--version")]).unwrap();
    assert_eq!(action, McpAction::PrintVersion);
}

#[test]
fn parses_mcp_no_args_as_server() {
    let action = parse_mcp_invocation(Vec::new()).unwrap();
    assert_eq!(action, McpAction::RunServer);
}

#[test]
fn rejects_mcp_positional_args() {
    let error = parse_mcp_invocation(vec![OsString::from("doctor")]).unwrap_err();
    assert!(error.contains("Unknown makevn-mcp option"));
}

#[test]
fn final_dashboard_prints_ok_on_success() {
    let lines = super::final_dashboard_lines(Duration::from_secs(3), &[], true);
    assert_eq!(lines[0], "Worked  for 3s");
    assert_eq!(lines[1], "[ok]");
    assert_eq!(lines[0].find("for"), "Working for 3s >".find("for"));
}

#[test]
fn final_dashboard_omits_ok_on_failure() {
    let lines = super::final_dashboard_lines(Duration::from_secs(3), &[], false);
    assert_eq!(lines[0], "Worked  for 3s");
    assert_eq!(lines.len(), 1);
}

#[test]
fn final_dashboard_shows_failure_summary() {
    let summary = CommandSummary {
        title: String::from("mutation"),
        duration: String::from("9m 34s"),
        log_path: Some(String::from("/repo/.makevn/logs/mutation.log")),
        relative_log_path: Some(String::from(".makevn/logs/mutation.log")),
        exit_code: 130,
        detail_lines: vec![
            String::from("WARNING: Mutation testing (PIT) is VERY slow. This can take 30+ minutes depending on project size."),
            String::from("PIT runs the full test suite multiple times against generated mutants."),
        ],
    };

    let lines = super::final_dashboard_lines(Duration::from_secs(574), &[summary], false);

    assert_eq!(lines[0], "Worked  for 9m 34s");
    assert_eq!(
        lines[1],
        "[x] mutation | 9m 34s | .makevn/logs/mutation.log"
    );
    assert_eq!(lines[2], "│ WARNING: Mutation testing (PIT) is VERY slow. This can take 30+ minutes depending on project size.");
    assert_eq!(
        lines[3],
        "│ PIT runs the full test suite multiple times against generated mutants."
    );
    assert_eq!(lines.len(), 4);
}

#[test]
fn backend_tail_notice_line_contains_log_path() {
    let metadata = BackendMetadata {
        command: String::from("mutation"),
        repo: String::from("/repo"),
        cwd: String::from("/repo"),
        log_path: String::from("/repo/.makevn/logs/mutation.log"),
        relative_log_path: String::from(".makevn/logs/mutation.log"),
        command_display: String::from("mutation"),
        title: String::from("mutation"),
        context: Some(String::from("code")),
    };
    let line = super::backend_tail_notice_line(&metadata);
    assert_eq!(line, " └ tailing log: .makevn/logs/mutation.log");
}

#[test]
fn tail_hint_contains_plus_minus() {
    let hint = super::tail_hint("esc interrupt");
    assert!(hint.contains("+/-"));
    assert!(hint.contains("t hide tail"));
    assert!(hint.contains("esc interrupt"));
}

#[test]
fn dashboard_hint_advertises_tail_toggle() {
    assert_eq!(
        dashboard_hint(&spinner_hint("interrupt")),
        "t tail | esc interrupt"
    );
}

#[test]
fn resource_sample_uses_fixed_width_columns() {
    let low = ResourceSample {
        cpu_percent: 17.4,
        rss_kb: 2202009,
    };
    let high = ResourceSample {
        cpu_percent: 142.1,
        rss_kb: 411443,
    };
    let mut history = ResourceHistory::new();
    history.push(ResourceSample {
        cpu_percent: 38.0,
        rss_kb: 128 * 1024,
    });
    history.push(ResourceSample {
        cpu_percent: 64.0,
        rss_kb: 220 * 1024,
    });
    history.push(ResourceSample {
        cpu_percent: 120.0,
        rss_kb: 320 * 1024,
    });
    history.push(ResourceSample {
        cpu_percent: 88.0,
        rss_kb: 256 * 1024,
    });
    history.push(ResourceSample {
        cpu_percent: 52.0,
        rss_kb: 180 * 1024,
    });
    history.push(ResourceSample {
        cpu_percent: 17.4,
        rss_kb: 2202009,
    });

    assert_eq!(
        format_resource_sample(&low, &history),
        "cpu ▁▂▃▂▁    17% | ram  ▁▁▁▁▇  2.10 GiB"
    );
    assert_eq!(
        format_resource_sample(&high, &history),
        "cpu ▁▂▃▂▁   142% | ram  ▁▁▁▁▇  402 MiB"
    );
}

#[test]
fn normalizes_repo_for_doctor_dispatch() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![
        OsString::from("--repo"),
        repo_root.clone(),
        OsString::from("doctor"),
    ])
    .unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![BackendInvocation {
            args: vec![
                OsString::from("doctor"),
                OsString::from("--repo"),
                repo_root,
            ],
            frontend_loader: false,
            tail: false,
            compact: false,
        }])
    );
}

#[test]
fn splits_top_level_command_sequence() {
    let segments = split_command_segments(vec![
        OsString::from("clean"),
        OsString::from("verify-it"),
        OsString::from("--tail"),
    ])
    .unwrap();

    assert_eq!(
        segments,
        vec![
            (OsString::from("clean"), Vec::new()),
            (OsString::from("verify-it"), vec![OsString::from("--tail")]),
        ]
    );
}

#[test]
fn does_not_split_test_name_as_command() {
    let segments = split_command_segments(vec![
        OsString::from("test"),
        OsString::from("--name"),
        OsString::from("verify-it"),
    ])
    .unwrap();

    assert_eq!(
        segments,
        vec![(
            OsString::from("test"),
            vec![OsString::from("--name"), OsString::from("verify-it")],
        ),]
    );
}

#[test]
fn parses_command_sequence_for_backend_dispatch() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![
        OsString::from("clean"),
        OsString::from("verify-it"),
        OsString::from("--tail"),
    ])
    .unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![
            BackendInvocation {
                args: vec![
                    OsString::from("clean"),
                    OsString::from("--repo"),
                    repo_root.clone(),
                ],
                frontend_loader: true,
                tail: true,
                compact: false,
            },
            BackendInvocation {
                args: vec![
                    OsString::from("verify-it"),
                    OsString::from("--repo"),
                    repo_root,
                ],
                frontend_loader: true,
                tail: true,
                compact: false,
            },
        ])
    );
}

#[test]
fn parses_global_tail_prefix_for_command_sequence() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![
        OsString::from("--tail"),
        OsString::from("clean"),
        OsString::from("verify-it"),
    ])
    .unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![
            BackendInvocation {
                args: vec![
                    OsString::from("clean"),
                    OsString::from("--repo"),
                    repo_root.clone(),
                ],
                frontend_loader: true,
                tail: true,
                compact: false,
            },
            BackendInvocation {
                args: vec![
                    OsString::from("verify-it"),
                    OsString::from("--repo"),
                    repo_root,
                ],
                frontend_loader: true,
                tail: true,
                compact: false,
            },
        ])
    );
}

#[test]
fn parses_global_compact_prefix_for_command_sequence() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![
        OsString::from("--compact"),
        OsString::from("clean"),
        OsString::from("verify-it"),
    ])
    .unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![
            BackendInvocation {
                args: vec![
                    OsString::from("clean"),
                    OsString::from("--repo"),
                    repo_root.clone(),
                    OsString::from("--compact"),
                ],
                frontend_loader: true,
                tail: false,
                compact: true,
            },
            BackendInvocation {
                args: vec![
                    OsString::from("verify-it"),
                    OsString::from("--repo"),
                    repo_root,
                    OsString::from("--compact"),
                ],
                frontend_loader: true,
                tail: false,
                compact: true,
            },
        ])
    );
}

#[test]
fn compact_keeps_final_report_brief() {
    let invocations = vec![BackendInvocation {
        args: vec![OsString::from("compile")],
        frontend_loader: true,
        tail: false,
        compact: true,
    }];

    assert!(!invocations
        .iter()
        .any(|invocation| invocation.frontend_loader && !invocation.compact));
}

#[test]
fn parses_command_sequence_with_options_per_command() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![
        OsString::from("clean"),
        OsString::from("--tail"),
        OsString::from("verify-it"),
        OsString::from("--tail"),
    ])
    .unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![
            BackendInvocation {
                args: vec![
                    OsString::from("clean"),
                    OsString::from("--repo"),
                    repo_root.clone(),
                ],
                frontend_loader: true,
                tail: true,
                compact: false,
            },
            BackendInvocation {
                args: vec![
                    OsString::from("verify-it"),
                    OsString::from("--repo"),
                    repo_root,
                ],
                frontend_loader: true,
                tail: true,
                compact: false,
            },
        ])
    );
}

#[test]
fn rejects_retired_make_commands() {
    for args in [
        vec!["make", "install"],
        vec!["make", "uninstall"],
        vec!["make", "--help"],
    ] {
        let error = parse_invocation(args.into_iter().map(OsString::from).collect()).unwrap_err();
        assert!(error.contains("Unknown command: make"), "{error}");
    }
}

#[test]
fn keeps_karate_tag_value_with_karate_command() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![
        OsString::from("karate-test"),
        OsString::from("--tag"),
        OsString::from("@smoke"),
    ])
    .unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![BackendInvocation {
            args: vec![
                OsString::from("karate-test"),
                OsString::from("--repo"),
                repo_root,
                OsString::from("--tag"),
                OsString::from("@smoke"),
            ],
            frontend_loader: true,
            tail: false,
            compact: false,
        }])
    );
}

#[test]
fn keeps_intermediate_tail_local_to_its_command() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![
        OsString::from("clean"),
        OsString::from("--tail"),
        OsString::from("verify-it"),
    ])
    .unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![
            BackendInvocation {
                args: vec![
                    OsString::from("clean"),
                    OsString::from("--repo"),
                    repo_root.clone(),
                ],
                frontend_loader: true,
                tail: true,
                compact: false,
            },
            BackendInvocation {
                args: vec![
                    OsString::from("verify-it"),
                    OsString::from("--repo"),
                    repo_root,
                ],
                frontend_loader: true,
                tail: false,
                compact: false,
            },
        ])
    );
}

#[test]
fn strips_tail_for_managed_log_command() {
    let (args, tail) = strip_frontend_tail_flag(
        &OsString::from("build"),
        vec![
            OsString::from("--tail"),
            OsString::from("--"),
            OsString::from("-DskipTests"),
        ],
    )
    .unwrap();

    assert!(tail);
    assert_eq!(
        args,
        vec![OsString::from("--"), OsString::from("-DskipTests")]
    );
}

#[test]
fn rejects_tail_for_state_command() {
    let error = strip_frontend_tail_flag(&OsString::from("doctor"), vec![OsString::from("--tail")])
        .unwrap_err();
    assert_eq!(
        error,
        "--tail is only supported for managed-log run commands, not doctor"
    );
}

#[test]
fn marks_compile_for_frontend_loader() {
    assert!(command_supports_frontend_loader(&OsString::from("compile")));
    assert!(command_supports_frontend_loader(&OsString::from(
        "test-compile"
    )));
    assert!(command_supports_frontend_loader(&OsString::from("verify")));
    assert!(command_supports_frontend_loader(&OsString::from(
        "coverage-changes"
    )));
    assert!(command_supports_frontend_loader(&OsString::from("crap")));
    assert!(command_supports_frontend_loader(&OsString::from(
        "docker-up"
    )));
    assert!(command_supports_frontend_loader(&OsString::from(
        "docker-ps-required"
    )));
    assert!(command_supports_frontend_loader(&OsString::from(
        "docker-stats"
    )));
    assert!(command_supports_frontend_loader(&OsString::from(
        "karate-docker-up"
    )));
    assert!(command_supports_frontend_loader(&OsString::from(
        "karate-docker-down"
    )));
    assert!(command_supports_frontend_loader(&OsString::from(
        "karate-test"
    )));
    assert!(command_supports_frontend_loader(&OsString::from(
        "karate-all"
    )));
    assert!(command_supports_frontend_loader(&OsString::from("run-app")));
    assert!(!command_supports_frontend_loader(&OsString::from("doctor")));
    assert!(!command_supports_frontend_loader(&OsString::from("run")));
}

#[test]
fn parses_verify_coverage_then_crap_with_ordered_loader_steps() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![
        OsString::from("verify-ut-coverage"),
        OsString::from("crap"),
    ])
    .unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![
            BackendInvocation {
                args: vec![
                    OsString::from("verify-ut-coverage"),
                    OsString::from("--repo"),
                    repo_root.clone(),
                ],
                frontend_loader: true,
                tail: false,
                compact: false,
            },
            BackendInvocation {
                args: vec![OsString::from("crap"), OsString::from("--repo"), repo_root,],
                frontend_loader: true,
                tail: false,
                compact: false,
            },
        ])
    );
}

#[test]
fn parses_run_app_tail_as_frontend_loader_command() {
    let repo_root = current_repo_root();
    let action =
        parse_invocation(vec![OsString::from("run-app"), OsString::from("--tail")]).unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![BackendInvocation {
            args: vec![
                OsString::from("run-app"),
                OsString::from("--repo"),
                repo_root,
            ],
            frontend_loader: true,
            tail: true,
            compact: false,
        }])
    );
}

#[test]
fn parses_run_app_help_without_backend_dispatch() {
    let action =
        parse_invocation(vec![OsString::from("run-app"), OsString::from("--help")]).unwrap();

    assert_eq!(
        action,
        Action::PrintCommandHelp {
            command: String::from("run-app"),
        }
    );
}

#[test]
fn all_top_level_commands_have_command_help() {
    let commands = [
        "help",
        "doctor",
        "init",
        "uninstall",
        "profile",
        "compile",
        "test-compile",
        "compile-tests",
        "validate",
        "package",
        "clean",
        "build",
        "test",
        "verify-ut",
        "verify-ut-coverage",
        "verify-it",
        "verify-it-coverage",
        "verify",
        "verify-changes-preview",
        "verify-changes",
        "coverage",
        "coverage-changes",
        "crap",
        "pr-verify",
        "format",
        "checkstyle",
        "docker-up",
        "docker-down",
        "docker-ps",
        "docker-stats",
        "docker-ps-required",
        "karate-docker-up",
        "karate-docker-down",
        "karate-test",
        "karate-all",
        "run-app",
        "run-app-bg",
        "stop-app",
        "run",
        "jdk",
        "mutation",
    ];

    for command in commands {
        assert!(
            command_help(command).is_some(),
            "missing help for {command}"
        );
    }
}

#[test]
fn parses_karate_all_as_frontend_loader_command() {
    let repo_root = current_repo_root();
    let action =
        parse_invocation(vec![OsString::from("karate-all"), OsString::from("--tail")]).unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![BackendInvocation {
            args: vec![
                OsString::from("karate-all"),
                OsString::from("--repo"),
                repo_root,
            ],
            frontend_loader: true,
            tail: true,
            compact: false,
        }])
    );
}

#[test]
fn parses_test_compile_command_for_backend_dispatch() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![OsString::from("test-compile")]).unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![BackendInvocation {
            args: vec![
                OsString::from("test-compile"),
                OsString::from("--repo"),
                repo_root,
            ],
            frontend_loader: true,
            tail: false,
            compact: false,
        }])
    );
}

#[test]
fn parses_format_apply_as_loader_command() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![
        OsString::from("format"),
        OsString::from("--apply"),
        OsString::from("--tail"),
    ])
    .unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![BackendInvocation {
            args: vec![
                OsString::from("format"),
                OsString::from("--repo"),
                repo_root,
                OsString::from("--apply"),
            ],
            frontend_loader: true,
            tail: true,
            compact: false,
        }])
    );
}

#[test]
fn parses_checkstyle_module_verbose_as_loader_command() {
    let repo_root = current_repo_root();
    let action = parse_invocation(vec![
        OsString::from("checkstyle"),
        OsString::from("--module"),
        OsString::from("domain"),
        OsString::from("--verbose"),
        OsString::from("--tail"),
    ])
    .unwrap();

    assert_eq!(
        action,
        Action::DispatchToBackend(vec![BackendInvocation {
            args: vec![
                OsString::from("checkstyle"),
                OsString::from("--repo"),
                repo_root,
                OsString::from("--module"),
                OsString::from("domain"),
                OsString::from("--verbose"),
            ],
            frontend_loader: true,
            tail: true,
            compact: false,
        }])
    );
}

#[test]
fn inserts_backend_option_before_forwarded_args() {
    let mut args = vec![
        OsString::from("build"),
        OsString::from("--repo"),
        OsString::from("/repo"),
        OsString::from("--"),
        OsString::from("-DskipTests"),
    ];

    insert_backend_option(&mut args, "--metadata-out", OsString::from("/tmp/meta"));

    assert_eq!(
        args,
        vec![
            OsString::from("build"),
            OsString::from("--repo"),
            OsString::from("/repo"),
            OsString::from("--metadata-out"),
            OsString::from("/tmp/meta"),
            OsString::from("--"),
            OsString::from("-DskipTests"),
        ]
    );
}

#[test]
fn reads_backend_metadata_file() {
    let unique_suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let metadata_path = env::temp_dir().join(format!(
        "makevn-test-{}-{unique_suffix}.meta",
        process::id()
    ));

    fs::write(
        &metadata_path,
        concat!(
            "command=build\n",
            "repo=/repo\n",
            "cwd=/repo\n",
            "log_path=/repo/.makevn/logs/build.log\n",
            "relative_log_path=.makevn/logs/build.log\n",
            "command_display=./mvnw -f /repo/pom.xml package -DskipTests\n",
            "title=build\n",
            "context=code\n"
        ),
    )
    .unwrap();

    let metadata = read_backend_metadata(&metadata_path).unwrap().unwrap();

    assert_eq!(metadata.command, "build");
    assert_eq!(metadata.relative_log_path, ".makevn/logs/build.log");
    assert_eq!(metadata.title, "build");
    assert_eq!(metadata.context.as_deref(), Some("code"));

    fs::remove_file(metadata_path).unwrap();
}

#[test]
fn tail_window_same_log_metadata_update_preserves_reader_and_painted_rows() {
    let path = env::temp_dir().join(format!("makevn-tail-same-log-{}.log", process::id()));
    fs::write(&path, "first\npartial").unwrap();
    let mut window = None;
    super::LogTailWindow::follow_log(&mut window, path.clone());
    let tail = window.as_mut().unwrap();
    tail.adjust_lines(3);
    tail.read_available().unwrap();
    tail.rendered_lines = 8;
    tail.rendered_line_widths = vec![10; 8];
    let offset = tail.offset;

    super::LogTailWindow::follow_log(&mut window, path.clone());
    let tail = window.as_mut().unwrap();
    assert_eq!(tail.offset, offset);
    assert!(tail.file.is_some());
    assert_eq!(tail.lines, vec!["first"]);
    assert_eq!(tail.pending, b"partial");
    assert_eq!(tail.visible_lines, 7);
    assert_eq!(tail.rendered_lines, 8);
    assert_eq!(tail.rendered_line_widths, vec![10; 8]);
    tail.read_available().unwrap();
    assert_eq!(
        tail.lines,
        vec!["first"],
        "metadata updates must not replay logs"
    );
    fs::remove_file(path).unwrap();
}

#[test]
fn tail_window_phase_change_resets_log_but_preserves_painted_rows_and_height() {
    let old_path = env::temp_dir().join(format!("makevn-tail-old-phase-{}.log", process::id()));
    let new_path = env::temp_dir().join(format!("makevn-tail-new-phase-{}.log", process::id()));
    fs::write(&old_path, "old phase\npending").unwrap();
    fs::write(&new_path, "new phase\n").unwrap();
    let mut window = None;
    super::LogTailWindow::follow_log(&mut window, old_path.clone());
    let tail = window.as_mut().unwrap();
    tail.read_available().unwrap();
    tail.adjust_lines(2);
    tail.rendered_lines = 7;
    tail.rendered_width = 100;
    tail.rendered_line_widths = vec![15; 7];

    super::LogTailWindow::follow_log(&mut window, new_path.clone());
    let tail = window.as_mut().unwrap();
    assert_eq!(tail.path, new_path);
    assert!(tail.file.is_none());
    assert_eq!(tail.offset, 0);
    assert!(tail.pending.is_empty());
    assert!(tail.lines.is_empty());
    assert_eq!(tail.visible_lines, 6);
    assert_eq!(tail.rendered_lines, 7);
    assert_eq!(tail.rendered_width, 100);
    assert_eq!(tail.rendered_line_widths, vec![15; 7]);
    tail.read_available().unwrap();
    assert_eq!(tail.lines, vec!["new phase"]);
    fs::remove_file(old_path).unwrap();
    fs::remove_file(new_path).unwrap();
}

#[test]
fn tail_window_restarts_after_log_truncation() {
    let unique_suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let log_path = env::temp_dir().join(format!(
        "makevn-tail-window-{}-{unique_suffix}.log",
        process::id()
    ));

    fs::write(&log_path, "first\nsecond\n").unwrap();

    let mut tail_window = super::LogTailWindow::new(log_path.clone());
    tail_window.read_available().unwrap();
    assert_eq!(
        tail_window.lines,
        vec![String::from("first"), String::from("second")]
    );

    let mut file = fs::File::create(&log_path).unwrap();
    file.write_all(b"third\n").unwrap();
    file.flush().unwrap();

    tail_window.read_available().unwrap();
    assert_eq!(tail_window.lines, vec![String::from("third")]);

    fs::remove_file(log_path).unwrap();
}

#[test]
fn tail_window_finish_flushes_pending_unterminated_line() {
    let log_path = env::temp_dir().join(format!("makevn-tail-finish-{}.log", process::id()));
    let mut tail_window = super::LogTailWindow::new(log_path);
    tail_window.pending.extend_from_slice(b"last line");
    tail_window.finish().unwrap();
    assert_eq!(tail_window.lines, vec![String::from("last line")]);
    assert!(tail_window.pending.is_empty());
}

#[test]
fn tail_window_clear_resets_rendered_state() {
    let mut tail_window = super::LogTailWindow::new(
        env::temp_dir().join(format!("makevn-tail-clear-{}.log", process::id())),
    );
    tail_window.clear().unwrap();
    assert_eq!(tail_window.rendered_lines, 0);

    tail_window.rendered_lines = 2;
    tail_window.rendered_line_widths = vec![1, 1];
    tail_window.clear().unwrap();
    assert_eq!(tail_window.rendered_lines, 0);
    assert!(tail_window.rendered_line_widths.is_empty());
}

#[test]
fn tail_status_lines_put_completed_commands_above_running_tail() {
    let summary = CommandSummary {
        title: String::from("format"),
        duration: String::from("6s"),
        log_path: Some(String::from("/repo/.makevn/logs/format.log")),
        relative_log_path: Some(String::from(".makevn/logs/format.log")),
        exit_code: 0,
        detail_lines: Vec::new(),
    };
    let metadata = BackendMetadata {
        command: String::from("checkstyle"),
        repo: String::from("/repo"),
        cwd: String::from("/repo"),
        log_path: String::from("/repo/.makevn/logs/checkstyle.log"),
        relative_log_path: String::from(".makevn/logs/checkstyle.log"),
        command_display: String::from("mvn checkstyle:check"),
        title: String::from("checkstyle"),
        context: Some(String::from("code")),
    };

    let lines = tail_status_lines(Duration::from_secs(13), &[summary], &metadata);

    assert_eq!(lines[0], "Working for 13s >");
    assert_eq!(lines[1], "[✓] format | 6s | .makevn/logs/format.log");
    assert_eq!(lines[2], "[•] makevn checkstyle");
    assert_eq!(lines[3], " └ tailing log: .makevn/logs/checkstyle.log");
}

#[test]
fn tail_window_places_loader_after_tailed_log() {
    let log_path = env::temp_dir().join("makevn-tail-loader-order.log");
    let mut tail_window = super::LogTailWindow::new(log_path);
    tail_window.set_prefix_lines(vec![
        String::from("Working for 1s >"),
        String::from("[•] makevn compile"),
        String::from("-> tailing log: .makevn/logs/compile.log"),
    ]);
    tail_window.set_loader_line(Some(String::from("........  esc interrupt")));
    tail_window.lines.push(String::from("[INFO] compiling"));

    let lines = tail_window.rendered_output_lines(120, 1);

    assert_eq!(lines[0], "Working for 1s >");
    assert_eq!(lines[1], "[•] makevn compile");
    assert_eq!(lines[2], "-> tailing log: .makevn/logs/compile.log");
    assert_eq!(lines[4], "........  esc interrupt");
    assert_eq!(
        super::visible_char_count(&lines[3]),
        "[INFO] compiling".len()
    );
}

#[test]
fn tail_window_footer_follows_reserved_rows_and_is_truncated() {
    let mut window = super::LogTailWindow::new(env::temp_dir().join("tail-footer.log"));
    window.set_loader_line(Some(String::from("telemetry and controls")));
    let lines = window.rendered_output_lines(8, 4);
    assert_eq!(
        &lines[..4],
        &[String::new(), String::new(), String::new(), String::new()]
    );
    assert_eq!(lines[4], "teleme~");
    window.set_loader_line(None);
    assert_eq!(window.rendered_output_lines(8, 4).len(), 4);
}

#[test]
fn dashboard_shows_summaries_and_current_details() {
    let metadata = BackendMetadata {
        command: String::from("coverage-changes"),
        repo: String::from("/repo"),
        cwd: String::from("/repo"),
        log_path: String::from("/repo/.makevn/logs/coverage-changes.log"),
        relative_log_path: String::from(".makevn/logs/coverage-changes.log"),
        command_display: String::from("coverage-changes"),
        title: String::from("coverage-changes"),
        context: Some(String::from("code")),
    };
    let completed = vec![CommandSummary {
        title: String::from("verify-it"),
        duration: String::from("4m 51s"),
        log_path: Some(String::from("/repo/.makevn/logs/verify-it.log")),
        relative_log_path: Some(String::from(".makevn/logs/verify-it.log")),
        exit_code: 0,
        detail_lines: vec![String::from("worked")],
    }];
    let current_details = vec![String::from("coverage-changes detail")];

    let lines = super::dashboard_output_lines(
        Duration::from_secs(5),
        &completed,
        &current_details,
        &metadata,
        0,
        0.0,
        "interrupt",
    );

    assert_eq!(lines[0], "Working for 5s >");
    assert_eq!(
        lines[1],
        "[✓] verify-it | 4m 51s | .makevn/logs/verify-it.log"
    );
    assert_eq!(lines[2], "│ worked");
    assert_eq!(
        lines[3],
        "[•] makevn coverage-changes | .makevn/logs/coverage-changes.log"
    );
    assert_eq!(lines[4], "│ coverage-changes detail");
    assert!(lines[5].contains("interrupt"));
    assert_eq!(lines.len(), 6);
}

#[test]
fn final_dashboard_places_details_under_completed_command() {
    let summary = CommandSummary {
        title: String::from("coverage-changes"),
        duration: String::from("9s"),
        log_path: Some(String::from("/repo/.makevn/logs/coverage-changes.log")),
        relative_log_path: Some(String::from(".makevn/logs/coverage-changes.log")),
        exit_code: 0,
        detail_lines: vec![String::from("coverage detail")],
    };

    let lines = super::final_dashboard_lines(Duration::from_secs(5), &[summary], true);

    assert_eq!(lines[0], "Worked  for 5s");
    assert_eq!(
        lines[1],
        "[✓] coverage-changes | 9s | .makevn/logs/coverage-changes.log"
    );
    assert_eq!(lines[2], "│ coverage detail");
    assert_eq!(lines[3], "[ok]");
}

#[test]
fn final_dashboard_does_not_prefix_box_detail_lines() {
    let summary = CommandSummary {
        title: String::from("coverage-changes"),
        duration: String::from("9s"),
        log_path: None,
        relative_log_path: None,
        exit_code: 0,
        detail_lines: vec![
            String::from("┌  Coverage summary"),
            String::from("│  threshold        95.00%"),
            String::from("├  Incremental lines"),
            String::from("✓  changed lines    96.00%  453/469"),
            String::from("└  passed"),
        ],
    };

    let lines = super::final_dashboard_lines(Duration::from_secs(9), &[summary], true);

    assert_eq!(lines[2], "┌  Coverage summary");
    assert_eq!(lines[3], "│  threshold        95.00%");
    assert_eq!(lines[4], "├  Incremental lines");
    assert_eq!(lines[5], "│ ✓  changed lines    96.00%  453/469");
    assert_eq!(lines[6], "└  passed");
}

#[test]
fn running_command_line_uses_fixed_marker_for_logged_commands() {
    let metadata = BackendMetadata {
        command: String::from("verify"),
        repo: String::from("/repo"),
        cwd: String::from("/repo"),
        log_path: String::from("/repo/.makevn/logs/verify.log"),
        relative_log_path: String::from(".makevn/logs/verify.log"),
        command_display: String::from("mvn verify"),
        title: String::from("verify"),
        context: Some(String::from("code")),
    };

    assert_eq!(
        super::running_command_line(&metadata),
        "[•] makevn verify | .makevn/logs/verify.log"
    );
}

#[test]
fn active_action_color_uses_reference_gold_only_with_truecolor_support() {
    for colorterm in ["truecolor", "24bit", "TRUECOLOR"] {
        assert_eq!(
            super::active_action_color_code(Some(colorterm), Some("xterm-256color")),
            "38;2;227;193;104"
        );
    }
    assert_eq!(
        super::active_action_color_code(None, Some("xterm-direct")),
        "38;2;227;193;104"
    );
    for colorterm in [None, Some(""), Some("256color")] {
        assert_eq!(
            super::active_action_color_code(colorterm, Some("xterm-256color")),
            "33"
        );
    }
    assert_eq!(super::active_action_color_code(None, None), "33");
}

#[test]
fn pending_backend_status_uses_one_line_before_metadata_arrives() {
    let line = super::pending_command_line("verify-changes");

    assert_eq!(line, "makevn verify-changes");
    assert!(!line.contains("Working for"));
    assert!(!line.contains('\n'));
    assert!(super::visible_char_count(&super::status_line_text_for_width(&line, 20)) < 20);
}

#[test]
fn terminal_width_from_columns_ignores_invalid_values() {
    assert_eq!(super::terminal_width_from_columns(Some("160")), Some(160));
    assert_eq!(super::terminal_width_from_columns(Some("0")), None);
    assert_eq!(super::terminal_width_from_columns(Some("wide")), None);
    assert_eq!(super::terminal_width_from_columns(None), None);
}

#[test]
fn truncate_ansi_line_counts_visible_chars_only() {
    assert_eq!(
        super::visible_char_count("\u{1b}[90mWorking for 52s >\u{1b}[0m"),
        17
    );
    let truncated = super::truncate_ansi_line("\u{1b}[90mWorking for 52s >\u{1b}[0m", 8);
    assert!(truncated.starts_with("\u{1b}[90mWorking~"));
    assert_eq!(super::visible_char_count(&truncated), 8);
}

#[test]
fn physical_rows_for_width_counts_each_rendered_line_after_resize() {
    assert_eq!(super::physical_rows_for_width(&[79, 79, 0], 80), 3);
    assert_eq!(super::physical_rows_for_width(&[79, 79, 0], 40), 5);
    assert_eq!(super::physical_rows_for_width(&[79, 12, 0], 20), 6);
}

#[test]
fn log_summary_uses_short_label() {
    assert_eq!(
        format!(
            "{} {}",
            dim_text("::"),
            dim_text("log: .makevn/logs/verify-it.log")
        ),
        format!(
            "{} {}",
            dim_text("::"),
            dim_text("log: .makevn/logs/verify-it.log")
        )
    );
}

#[test]
fn rejects_invalid_profile_subcommand() {
    let error = parse_invocation(vec![OsString::from("profile")]).unwrap_err();
    assert_eq!(error, "Usage: makevn profile refresh");
}

#[test]
fn rejects_unknown_command() {
    let error = parse_invocation(vec![OsString::from("wat")]).unwrap_err();
    assert_eq!(error, "Unknown command: wat");
}

#[test]
fn handles_help_command_in_frontend() {
    let action = parse_invocation(vec![OsString::from("help")]).unwrap();
    assert_eq!(action, Action::PrintHelp { with_header: true });
}

#[test]
fn metadata_parser_preserves_last_value_empty_fields_and_equals() {
    let content = "ignored\nunknown=value\ncommand=old\ncommand=test\nrepo=/repo\ncwd=\nlog_path=/log=a\nrelative_log_path=log\ncommand_display=mvn test\ntitle=Test\n";
    let metadata = super::parse_backend_metadata(content).unwrap();
    assert_eq!(metadata.command, "test");
    assert_eq!(metadata.cwd, "");
    assert_eq!(metadata.log_path, "/log=a");
    assert_eq!(metadata.context, None);
    let with_context = format!("{content}context=old\ncontext=karate\n");
    assert_eq!(
        super::parse_backend_metadata(&with_context)
            .unwrap()
            .context
            .as_deref(),
        Some("karate")
    );
    for key in [
        "command",
        "repo",
        "cwd",
        "log_path",
        "relative_log_path",
        "command_display",
        "title",
    ] {
        let incomplete = content
            .lines()
            .filter(|line| !line.starts_with(&format!("{key}=")))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            super::parse_backend_metadata(&incomplete).is_none(),
            "missing {key}"
        );
    }
}

#[test]
fn command_option_consumption_preserves_passthrough_and_values() {
    let mut passthrough = false;
    let mut expects_value = false;
    assert!(!super::consume_command_option(
        &"compile".into(),
        &mut passthrough,
        &mut expects_value
    ));
    assert!(super::consume_command_option(
        &"--name".into(),
        &mut passthrough,
        &mut expects_value
    ));
    assert!(expects_value);
    assert!(super::consume_command_option(
        &"verify".into(),
        &mut passthrough,
        &mut expects_value
    ));
    assert!(!expects_value);
    assert!(super::consume_command_option(
        &"--".into(),
        &mut passthrough,
        &mut expects_value
    ));
    assert!(super::consume_command_option(
        &"verify".into(),
        &mut passthrough,
        &mut expects_value
    ));
    assert!(passthrough);
    assert_eq!(
        split_command_segments(vec!["init".into(), "--force".into(), "doctor".into()]).unwrap(),
        vec![
            ("init".into(), vec!["--force".into()]),
            ("doctor".into(), vec![])
        ]
    );
}

#[test]
fn backend_invocation_preserves_tail_compact_and_forwarding() {
    let args = vec!["--tail".into(), "--".into(), "--tail".into()];
    let invocation =
        super::build_backend_invocation(Path::new("/repo"), "test".into(), args, false, true)
            .unwrap();
    assert!(invocation.tail && invocation.compact && invocation.frontend_loader);
    assert_eq!(
        invocation.args,
        vec![
            OsString::from("test"),
            "--repo".into(),
            "/repo".into(),
            "--compact".into(),
            "--".into(),
            "--tail".into()
        ]
    );
    let plain =
        super::build_backend_invocation(Path::new("/repo"), "doctor".into(), vec![], false, false)
            .unwrap();
    assert!(!plain.tail && !plain.frontend_loader && !plain.compact);
    assert!(super::build_backend_invocation(
        Path::new("/repo"),
        "doctor".into(),
        vec![],
        true,
        false
    )
    .unwrap_err()
    .contains("not doctor"));
    assert!(super::build_backend_invocation(
        Path::new("/repo"),
        "unknown".into(),
        vec![],
        false,
        false
    )
    .is_err());
}

#[test]
fn opencode_mcp_configuration_rejects_nonobject_fields() {
    let path = Path::new("config.json");
    let mut config = serde_json::json!([]);
    assert!(super::configure_opencode_mcp(&mut config, path)
        .unwrap_err()
        .contains("must be a JSON object"));
    let mut config = serde_json::json!({"mcp": false});
    assert_eq!(
        super::configure_opencode_mcp(&mut config, path).unwrap_err(),
        "OpenCode config field 'mcp' must be a JSON object"
    );
    let mut config = serde_json::json!({"other": 42, "mcp": {"existing": {"enabled": true}}});
    super::configure_opencode_mcp(&mut config, path).unwrap();
    assert_eq!(config["other"], 42);
    assert_eq!(config["mcp"]["existing"]["enabled"], true);
    assert_eq!(
        config["mcp"]["makevn"]["command"],
        serde_json::json!(["makevn-mcp"])
    );
}

#[test]
fn docker_connection_hint_predicate_requires_docker_for_generic_errors() {
    for message in [
        "cannot connect to the docker daemon",
        "is the docker daemon running",
        "docker: error during connect",
    ] {
        assert!(super::docker_connection_failed(message));
    }
    for message in [
        "error during connect",
        "docker build failed",
        "maven failed",
    ] {
        assert!(!super::docker_connection_failed(message));
    }
}

#[test]
fn spinner_background_and_pulse_handle_load_and_blank_frames() {
    assert_eq!(super::spinner_background(None, 0, 0.0), " ");
    for load in [0.0, 0.01, 0.5, 1.0] {
        assert!(super::spinner_pulse_style("38;2;72;84;112", 30, load).contains('·'));
        let background = super::spinner_background(Some("38;2;72;84;112"), 30, load);
        assert!(!background.is_empty());
    }
}

#[test]
fn maven_usage_lookup_keeps_all_supported_commands_and_options() {
    for command in [
        "compile",
        "test-compile",
        "compile-tests",
        "validate",
        "package",
        "build",
        "clean",
        "verify-ut",
        "verify-ut-coverage",
        "verify-it",
        "verify-it-coverage",
        "verify",
        "verify-changes",
        "pr-verify",
    ] {
        let (usage, description, options) =
            super::maven_command_help(command, "description", false).unwrap();
        assert!(usage.contains(&format!(" {command} [--tail]")));
        assert_eq!(description, "description");
        assert_eq!(options.len(), 3);
        assert_eq!(
            super::maven_command_help(command, "description", true)
                .unwrap()
                .2
                .len(),
            4
        );
    }
    assert!(super::maven_command_help("doctor", "description", false).is_none());
}

#[test]
fn rejects_removed_exec_command() {
    assert!(super::command_help("exec").is_none());
    assert_eq!(
        parse_invocation(
            ["exec", "--", "mvn", "-v"]
                .into_iter()
                .map(OsString::from)
                .collect()
        )
        .unwrap_err(),
        "Unknown command: exec"
    );
}

#[test]
fn tail_window_reads_same_path_replacement_even_when_it_has_regrown() {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = env::temp_dir().join(format!("makevn-replaced-{}-{suffix}", process::id()));
    let replacement = path.with_extension("new");
    for content in ["new\n", "new\nlonger output\n"] {
        fs::write(&path, "old\n").unwrap();
        let mut tail = super::LogTailWindow::new(path.clone());
        tail.read_available().unwrap();
        tail.rendered_lines = 7;
        fs::write(&replacement, content).unwrap();
        fs::rename(&replacement, &path).unwrap();
        tail.read_available().unwrap();
        assert_eq!(
            tail.lines,
            content.lines().map(String::from).collect::<Vec<_>>()
        );
        assert_eq!(tail.offset, content.len() as u64);
        assert_eq!(tail.rendered_lines, 7);
        tail.read_available().unwrap();
        assert_eq!(tail.lines.len(), content.lines().count());
    }
    fs::remove_file(path).unwrap();
}

#[test]
fn karate_phase_records_preserve_order_status_duration_and_own_details() {
    let phases = super::BackendPhaseFiles::new().unwrap();
    for (index, title, code) in [
        (1, "karate-docker-up", 0),
        (3, "run-app-bg", 0),
        (5, "karate-test", 42),
    ] {
        fs::write(phases.0.join(index.to_string()), format!("command={title}\nrepo=/repo\ncwd=/repo\nlog_path=/repo/{title}.log\nrelative_log_path={title}.log\ncommand_display=makevn {title}\ntitle={title}\nduration_seconds=7\nexit_code={code}\n")).unwrap();
        fs::write(
            phases.0.join(format!("{index}.detail")),
            format!("details for {title}\n"),
        )
        .unwrap();
    }
    // A record being published is not yet a completed phase.
    fs::write(phases.0.join("4"), "command=docker-ps-required\n").unwrap();
    let summaries = phases.read();
    assert_eq!(summaries.len(), 3);
    assert_eq!(summaries[0].title, "karate-docker-up");
    assert_eq!(summaries[1].title, "run-app-bg");
    assert_eq!(summaries[2].title, "karate-test");
    assert_eq!(summaries[2].exit_code, 42);
    assert_eq!(summaries[2].duration, "7s");
    assert_eq!(
        summaries[2].relative_log_path.as_deref(),
        Some("karate-test.log")
    );
    assert_eq!(summaries[2].detail_lines, vec!["details for karate-test"]);
}

#[test]
fn doctor_accepts_compact_after_command() {
    let action = parse_invocation(vec![
        "--repo".into(),
        current_repo_root(),
        "doctor".into(),
        "--compact".into(),
    ])
    .unwrap();
    let Action::DispatchToBackend(invocations) = action else {
        panic!("expected backend dispatch")
    };
    assert!(invocations[0].compact);
    assert!(invocations[0].args.contains(&OsString::from("--compact")));
}

#[test]
fn terminal_presentation_never_leaks_into_agent_or_piped_output() {
    assert!(super::interactive_presentation(
        true, true, true, false, false
    ));
    assert!(!super::interactive_presentation(
        true, true, true, true, false
    ));
    assert!(!super::interactive_presentation(
        false, true, true, false, false
    ));
    assert!(!super::interactive_presentation(
        true, false, true, false, false
    ));
    assert!(!super::interactive_presentation(
        true, true, false, false, false
    ));
    assert!(!super::interactive_presentation(
        true, true, true, false, true
    ));
}

#[test]
fn state_metadata_reuses_dashboard_without_empty_log_suffix() {
    let path = std::env::temp_dir().join(format!("makevn-state-metadata-{}", std::process::id()));
    super::write_state_metadata(&path, "doctor", &OsString::from("/repo")).unwrap();
    let metadata = super::read_backend_metadata(&path).unwrap().unwrap();
    let summary = super::summary_from_backend_metadata(0, "1s".into(), "doctor", Some(&metadata));
    assert_eq!(summary.title, "doctor");
    assert_eq!(summary.log_path, None);
    assert_eq!(summary.relative_log_path, None);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn completion_records_include_state_phases_beyond_karate_five() {
    let files = super::BackendPhaseFiles::new().unwrap();
    for index in [6, 2, 1] {
        let path = files.0.join(index.to_string());
        super::write_state_metadata(&path, &format!("phase-{index}"), &OsString::from("/repo"))
            .unwrap();
        use std::io::Write;
        let mut record = std::fs::OpenOptions::new().append(true).open(path).unwrap();
        writeln!(record, "duration_seconds=1\nexit_code=0").unwrap();
    }
    assert_eq!(
        files
            .read()
            .iter()
            .map(|phase| phase.title.clone())
            .collect::<Vec<_>>(),
        vec!["phase-1", "phase-2", "phase-6"]
    );
}

#[test]
fn paused_dashboard_does_not_overwrite_interactive_prompt() {
    let mut renderer = SpinnerRenderer {
        tty: File::open("/dev/null").unwrap(),
        tty_guard: None,
        paused: true,
        frame: 0,
        frame_interval: std::time::Duration::ZERO,
        next_frame_at: std::time::Instant::now(),
        second_escape_deadline: None,
        resource_sampler: ResourceSampler::new(),
        resource_history: ResourceHistory::new(),
        resource_history_revision: 0,
        cpu_visual_load: 0.0,
        ram_visual_load: 0.0,
        resource_visual_load: 0.0,
        rendered_block_line_widths: Vec::new(),
    };
    let metadata = BackendMetadata {
        command: "doctor".into(),
        repo: "/repo".into(),
        cwd: "/repo".into(),
        log_path: String::new(),
        relative_log_path: String::new(),
        command_display: "makevn doctor".into(),
        title: "doctor".into(),
        context: None,
    };
    assert!(!renderer.current_metadata_hint(&metadata).contains("tail"));
    renderer
        .render_dashboard(0, std::time::Duration::ZERO, &[], &[], &metadata, "")
        .unwrap();
    assert_eq!(renderer.frame, 0);
    renderer.render_frame_with_hint(0, "").unwrap();
    assert_eq!(renderer.frame, 0);
}

#[test]
fn resume_after_prompt_restores_loader_input_without_resetting_history() {
    let mut master_fd = -1;
    let mut slave_fd = -1;
    assert_eq!(
        unsafe {
            libc::openpty(
                &mut master_fd,
                &mut slave_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        },
        0
    );
    let _master = unsafe { File::from_raw_fd(master_fd) };
    let tty = unsafe { File::from_raw_fd(slave_fd) };
    let original = super::get_termios(slave_fd).unwrap();
    let mut renderer = SpinnerRenderer {
        tty,
        tty_guard: None,
        paused: true,
        frame: 42,
        frame_interval: std::time::Duration::ZERO,
        next_frame_at: std::time::Instant::now(),
        second_escape_deadline: None,
        resource_sampler: ResourceSampler::new(),
        resource_history: ResourceHistory::new(),
        resource_history_revision: 0,
        cpu_visual_load: 0.0,
        ram_visual_load: 0.0,
        resource_visual_load: 0.0,
        rendered_block_line_widths: Vec::new(),
    };
    for _ in 0..2 {
        renderer.resume().unwrap();
        assert!(!renderer.paused && renderer.tty_guard.is_some());
        assert_eq!(
            super::get_termios(slave_fd).unwrap().c_lflag & libc::ICANON,
            0
        );
        assert_eq!(renderer.frame, 42);
        renderer.pause();
        assert!(renderer.paused && renderer.tty_guard.is_none());
        assert_eq!(
            super::get_termios(slave_fd).unwrap().c_lflag & (libc::ICANON | libc::ECHO),
            original.c_lflag & (libc::ICANON | libc::ECHO)
        );
    }
}

#[test]
fn pending_dashboard_marks_previous_command_completed_and_next_starting() {
    let metadata = super::pending_backend_metadata("docker-ps-required");
    assert_eq!(metadata.command_display, "makevn docker-ps-required");
    assert_eq!(
        super::running_command_line(&metadata),
        "[•] makevn docker-ps-required (starting)"
    );
    assert_eq!(
        super::backend_header_line(&metadata),
        "[•] makevn docker-ps-required (starting)"
    );
    assert!(metadata.log_path.is_empty());
    let summary = CommandSummary {
        title: "docker-up".to_owned(),
        duration: "2s".to_owned(),
        log_path: None,
        relative_log_path: None,
        exit_code: 0,
        detail_lines: vec!["retained detail".to_owned()],
    };
    let lines = super::dashboard_output_lines(
        Duration::from_secs(3),
        &[summary],
        &[],
        &metadata,
        0,
        0.0,
        "esc interrupt",
    );
    let output = lines.join("\n");
    assert!(output.contains("docker-up"));
    assert!(output.contains("retained detail"));
    assert!(output.contains("makevn docker-ps-required (starting)"));
    assert!(!output.contains("makevn docker-up"));
    assert!(!output.contains("t tail"));
}

#[test]
fn replay_backend_output_handles_missing_empty_and_nonempty_files() {
    let path = env::temp_dir().join(format!(
        "makevn-replay-{}-{}",
        process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    super::replay_backend_output(&path, None, false);
    fs::write(&path, "").unwrap();
    super::replay_backend_output(&path, None, false);
    fs::write(&path, "replayed backend output\n").unwrap();
    super::replay_backend_output(&path, None, false);
    super::replay_backend_output(&path, None, true);
    fs::remove_file(path).unwrap();
}

struct CountingOutput {
    bytes: u64,
    largest_write: usize,
}

impl Write for CountingOutput {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.bytes += bytes.len() as u64;
        self.largest_write = self.largest_write.max(bytes.len());
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn large_backend_output_is_replayed_in_bounded_chunks() {
    let path = env::temp_dir().join(format!(
        "makevn-stream-{}-{}",
        process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let mut output = CountingOutput {
        bytes: 0,
        largest_write: 0,
    };
    assert!(super::stream_backend_output(&path, None, &mut output).is_err());
    let file = File::create(&path).unwrap();
    assert_eq!(
        super::stream_backend_output(&path, None, &mut output).unwrap(),
        0
    );
    let length = 16 * 1024 * 1024;
    file.set_len(length).unwrap();
    assert_eq!(
        super::stream_backend_output(&path, None, &mut output).unwrap(),
        length
    );
    assert_eq!(output.bytes, length);
    assert!(
        output.largest_write <= 64 * 1024,
        "unbounded write: {}",
        output.largest_write
    );
    fs::remove_file(path).unwrap();
}

fn renderer_for_backend_boundary() -> SpinnerRenderer {
    SpinnerRenderer {
        tty: File::open("/dev/null").unwrap(),
        tty_guard: None,
        paused: false,
        frame: 17,
        frame_interval: Duration::ZERO,
        next_frame_at: Instant::now(),
        second_escape_deadline: Some(Instant::now() + Duration::from_secs(3)),
        resource_sampler: ResourceSampler::new(),
        resource_history: ResourceHistory::new(),
        resource_history_revision: 0,
        cpu_visual_load: 0.0,
        ram_visual_load: 0.0,
        resource_visual_load: 0.0,
        rendered_block_line_widths: vec![12, 30, 80],
    }
}

#[test]
fn backend_boundary_resets_escape_confirmation_without_clearing_dashboard() {
    let mut renderer = renderer_for_backend_boundary();
    renderer.begin_backend();
    assert!(renderer.second_escape_deadline.is_none());
    assert_eq!(renderer.rendered_block_line_widths, [12, 30, 80]);
    assert_eq!(renderer.frame, 17);
    assert!(matches!(
        super::decode_spinner_input(0x1b, &mut renderer.second_escape_deadline),
        InputEvent::None
    ));
    assert!(matches!(
        super::decode_spinner_input(0x1b, &mut renderer.second_escape_deadline),
        InputEvent::Interrupt
    ));
}

#[test]
fn backend_boundary_resets_telemetry_history_and_smoothed_loads() {
    let mut renderer = renderer_for_backend_boundary();
    let previous = ResourceSample {
        cpu_percent: 200.0,
        rss_kb: 1024 * 1024,
    };
    renderer.resource_sampler.last_pid = Some(99);
    renderer.resource_sampler.last_sample_at = Some(Instant::now());
    renderer.resource_sampler.last_sample = Some(previous);
    renderer.resource_sampler.sample_revision = 5;
    for _ in 0..5 {
        renderer.resource_history.push(previous);
    }
    renderer.resource_history_revision = 5;
    renderer.cpu_visual_load = 0.8;
    renderer.ram_visual_load = 0.7;
    renderer.resource_visual_load = 0.9;
    renderer.begin_backend();
    assert!(renderer.resource_sampler.last_pid.is_none());
    assert!(renderer.resource_sampler.last_sample.is_none());
    assert!(renderer.resource_sampler.last_sample_at.is_none());
    assert_eq!(renderer.resource_sampler.revision(), 0);
    assert!(renderer.resource_history.cpu_percent.is_empty());
    assert!(renderer.resource_history.rss_kb.is_empty());
    assert_eq!(renderer.resource_history_revision, 0);
    assert_eq!(renderer.cpu_visual_load, 0.0);
    assert_eq!(renderer.ram_visual_load, 0.0);
    assert_eq!(renderer.resource_visual_load, 0.0);
    assert_eq!(renderer.frame, 17);
    assert_eq!(renderer.rendered_block_line_widths, [12, 30, 80]);
    renderer.resource_history.push(ResourceSample {
        cpu_percent: 2.0,
        rss_kb: 64,
    });
    assert_eq!(renderer.resource_history.cpu_percent, [Some(2.0)]);
    assert_eq!(renderer.resource_history.rss_kb, [Some(64)]);
}

#[test]
fn backend_boundary_selects_docker_source_after_reset_and_clears_it_for_verify() {
    let mut renderer = renderer_for_backend_boundary();
    renderer.begin_backend();
    renderer.configure_resource_source(
        "docker-up",
        Some(std::path::PathBuf::from("/nonexistent/makevn.resources")),
    );
    assert!(renderer.resource_sampler.docker.is_some());
    assert!(renderer
        .resource_sampler
        .sample(std::process::id())
        .unwrap()
        .is_none());
    assert_eq!(
        renderer.resource_sampler.scoped_text(String::new(), None),
        format!(
            "ctr {}",
            super::format_unavailable_resource_metrics(&ResourceHistory::new())
        )
    );
    renderer.begin_backend();
    renderer.configure_resource_source("verify", None);
    assert!(renderer.resource_sampler.docker.is_none());
    assert!(renderer.resource_sampler.last_pid.is_none());
    assert_eq!(
        renderer
            .resource_sampler
            .scoped_text("cpu 2%".into(), Some(0.0)),
        "cpu 2%"
    );
    assert_eq!(renderer.rendered_block_line_widths, [12, 30, 80]);
    assert_eq!(renderer.frame, 17);
}

#[test]
fn docker_history_advances_at_two_second_ticks_with_missing_slots() {
    let mut history = ResourceHistory::new();
    let now = Instant::now();
    let sample = ResourceSample {
        cpu_percent: 250.0,
        rss_kb: 1024,
    };
    history.tick(now, Some(&sample));
    history.tick(now + Duration::from_millis(1999), None);
    assert_eq!(history.cpu_percent, [Some(250.0)]);
    history.tick(now + Duration::from_secs(2), None);
    assert_eq!(history.cpu_percent, [Some(250.0), None]);
    assert_eq!(history.rss_kb, [Some(1024), None]);
    assert_eq!(
        super::sparkline_f32(&history.cpu_percent, 6, 250.0),
        "    ▇ "
    );
    let missing = super::format_unavailable_resource_metrics(&history);
    assert!(missing.contains('▇'));
    assert!(missing.contains('—'));
    history.tick(now + Duration::from_secs(4), Some(&sample));
    assert_eq!(history.cpu_percent, [Some(250.0), None, Some(250.0)]);
    assert_eq!(
        super::sparkline_f32(&history.cpu_percent, 6, 250.0),
        "   ▇ ▇"
    );
    history.tick(now + Duration::from_secs(16), None);
    assert_eq!(history.cpu_percent, [None; 6]);
    assert_eq!(history.rss_kb, [None; 6]);
}

#[test]
fn missing_docker_metrics_keep_graph_and_value_columns() {
    let mut history = ResourceHistory::new();
    let sample = ResourceSample {
        cpu_percent: 250.0,
        rss_kb: 4096,
    };
    history.push(sample);
    let available = format_resource_sample(&sample, &history);
    let unavailable = super::format_unavailable_resource_metrics(&history);
    assert_eq!(
        super::visible_char_count(&available),
        super::visible_char_count(&unavailable)
    );
    assert_eq!(
        super::visible_char_count(available.split('|').next().unwrap()),
        super::visible_char_count(unavailable.split('|').next().unwrap())
    );
    assert!(unavailable.contains("cpu"));
    assert!(unavailable.contains("ram"));
}

#[test]
fn docker_scope_label_uses_cpu_color_and_dims_when_unavailable() {
    let mut sampler = ResourceSampler::new();
    sampler.configure_docker("docker-up", Some("/nonexistent/makevn.resources".into()));
    let metrics = super::adaptive_metric_text("cpu 20%", 0.4);
    assert_eq!(
        sampler.scoped_text(metrics.clone(), Some(0.4)),
        format!("{} {}", super::adaptive_metric_text("ctr", 0.4), metrics)
    );
    let unavailable = super::format_unavailable_resource_metrics(&ResourceHistory::new());
    assert_eq!(
        sampler.scoped_text(unavailable.clone(), None),
        format!("{} {}", dim_text("ctr"), unavailable)
    );
}

#[test]
fn format_help_does_not_advertise_removed_file_option() {
    let (usage, _, options) = command_help("format").unwrap();
    assert!(!usage.contains("--file"));
    assert!(options.iter().all(|option| !option.contains("--file")));
    assert!(options.iter().any(|option| option.contains("--apply")));
}

#[test]
fn doctor_reset_option_is_accepted_by_rust_dispatcher() {
    for args in [vec!["--reset-config"], vec!["--compact", "--reset-config"]] {
        let args: Vec<std::ffi::OsString> = args.into_iter().map(Into::into).collect();
        assert!(super::validate_command(&"doctor".into(), &args).is_ok());
    }
    assert!(super::validate_command(&"doctor".into(), &["--unknown".into()]).is_err());
}
