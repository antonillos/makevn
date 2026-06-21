use std::collections::{HashMap, HashSet};
use std::env;
use std::ffi::OsString;
use std::fmt;
use std::fs::{self, File};
use std::io::{self, IsTerminal, Read, Seek, SeekFrom, Write};
use std::mem::MaybeUninit;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(unix)]
use std::os::unix::process::{CommandExt, ExitStatusExt};

#[cfg(unix)]
use signal_hook::consts::signal::{SIGINT, SIGTERM};

mod mcp_server;

fn main() {
    let argv0 = env::args_os()
        .next()
        .unwrap_or_else(|| OsString::from("makevn"));
    if Path::new(&argv0)
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name == "makevn-mcp")
    {
        match parse_mcp_invocation(env::args_os().skip(1).collect()) {
            Ok(McpAction::PrintHelp) => {
                print_mcp_help();
                return;
            }
            Ok(McpAction::PrintVersion) => {
                println!("{}", makevn_version());
                return;
            }
            Ok(McpAction::RunServer) => {}
            Err(message) => exit_with_error(message),
        }
        let current_exe = match env::current_exe() {
            Ok(path) => path,
            Err(error) => exit_with_error(format!("failed to resolve current executable: {error}")),
        };
        let exit_code = match mcp_server::run_mcp_server(current_exe) {
            Ok(code) => code,
            Err(message) => exit_with_error(message),
        };
        process::exit(exit_code);
    }

    let action = match parse_invocation(env::args_os().skip(1).collect()) {
        Ok(action) => action,
        Err(message) => exit_with_error(message),
    };

    if let Action::PrintVersion = action {
        println!("{}", makevn_version());
        return;
    }

    if let Action::PrintHelp { with_header } = action {
        print_help(with_header);
        return;
    }

    if let Action::PrintCommandHelp { command } = action {
        print_command_help(&command);
        return;
    }

    if let Action::RunMcpServer = action {
        let current_exe = match env::current_exe() {
            Ok(path) => path,
            Err(error) => exit_with_error(format!("failed to resolve current executable: {error}")),
        };
        let exit_code = match mcp_server::run_mcp_server(current_exe) {
            Ok(code) => code,
            Err(message) => exit_with_error(message),
        };
        process::exit(exit_code);
    }

    let current_exe = match env::current_exe() {
        Ok(path) => path,
        Err(error) => exit_with_error(format!("failed to resolve current executable: {error}")),
    };

    let install_root = match install_root(&current_exe) {
        Ok(path) => path,
        Err(message) => exit_with_error(message),
    };

    let backend_path = install_root.join("libexec/makevn/backend.sh");
    if !backend_path.is_file() {
        exit_with_error(format!(
            "makevn runtime not found at {}",
            backend_path.display()
        ));
    }

    let backend_invocations = match action {
        Action::DispatchToBackend(invocations) => invocations,
        Action::PrintVersion => unreachable!(),
        Action::PrintHelp { .. } => unreachable!(),
        Action::PrintCommandHelp { .. } => unreachable!(),
        Action::RunMcpServer => unreachable!(),
    };

    let exit_code = match dispatch_backend_invocations(
        &backend_path,
        &current_exe,
        &install_root,
        backend_invocations,
    ) {
        Ok(code) => code,
        Err(message) => exit_with_error(message),
    };
    process::exit(exit_code);
}

fn makevn_version() -> &'static str {
    option_env!("MAKEVN_BUILD_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
}

#[derive(Debug, Eq, PartialEq)]
enum Action {
    PrintVersion,
    PrintHelp { with_header: bool },
    PrintCommandHelp { command: String },
    DispatchToBackend(Vec<BackendInvocation>),
    RunMcpServer,
}

#[derive(Debug, Eq, PartialEq)]
enum McpAction {
    PrintHelp,
    PrintVersion,
    RunServer,
}

#[derive(Debug, Eq, PartialEq)]
struct BackendInvocation {
    args: Vec<OsString>,
    frontend_loader: bool,
    tail: bool,
    compact: bool,
}

const COMMAND_SEQUENCE_BREAKERS: &[&str] = &[
    "--",
    "--tail",
    "--compact",
    "--name",
    "--context",
    "--threshold",
    "--tag",
    "--compose",
    "--module",
    "--wait-seconds",
];

#[derive(Debug)]
struct BackendMetadataFile {
    path: PathBuf,
}

#[derive(Debug)]
struct BackendDetailFile {
    path: PathBuf,
}

impl BackendDetailFile {
    fn new() -> Result<Self, String> {
        let unique_suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| format!("failed to resolve detail timestamp: {error}"))?
            .as_nanos();
        let path = env::temp_dir().join(format!("makevn-{}-{unique_suffix}.detail", process::id()));
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn read_lines(&self) -> Vec<String> {
        match fs::read_to_string(&self.path) {
            Ok(content) => content
                .lines()
                .filter(|l| !l.is_empty())
                .map(str::to_owned)
                .collect(),
            Err(_) => Vec::new(),
        }
    }

    fn clear(&self) {
        let _ = fs::write(&self.path, b"");
    }
}

impl Drop for BackendDetailFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[derive(Debug, Eq, PartialEq)]
struct BackendMetadata {
    command: String,
    repo: String,
    cwd: String,
    log_path: String,
    relative_log_path: String,
    command_display: String,
    title: String,
    context: Option<String>,
}

#[derive(Clone, Debug)]
struct CommandSummary {
    title: String,
    duration: String,
    log_path: Option<String>,
    relative_log_path: Option<String>,
    exit_code: i32,
    detail_lines: Vec<String>,
}

#[derive(Debug)]
struct BackendRunResult {
    exit_code: i32,
    summary: CommandSummary,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CommandValidation {
    Valid,
    ProfileRefresh,
    JdkSubcommand,
}

fn parse_invocation(args: Vec<OsString>) -> Result<Action, String> {
    let mut index = 0;
    let mut repo_override: Option<OsString> = None;
    let mut global_tail = false;
    let mut global_compact = false;

    while let Some(arg) = args.get(index) {
        match arg.to_string_lossy().as_ref() {
            "--repo" => {
                let value = args
                    .get(index + 1)
                    .cloned()
                    .ok_or_else(|| String::from("Missing value for --repo"))?;
                repo_override = Some(value);
                index += 2;
            }
            "--tail" => {
                global_tail = true;
                index += 1;
            }
            "--compact" => {
                global_compact = true;
                index += 1;
            }
            "--mcp" | "serve" => {
                return Ok(Action::RunMcpServer);
            }
            "--help" | "-h" => {
                return Ok(Action::PrintHelp { with_header: false });
            }
            "--version" => return Ok(Action::PrintVersion),
            _ => break,
        }
    }

    let command = args
        .get(index)
        .cloned()
        .unwrap_or_else(|| OsString::from("help"));
    let command_segments = split_command_segments(args[index..].to_vec())?;
    let trailing_args = command_segments
        .first()
        .map(|segment| segment.1.clone())
        .unwrap_or_default();

    let command_validation = validate_command(&command, &trailing_args)?;

    if trailing_args
        .iter()
        .any(|arg| matches!(arg.to_string_lossy().as_ref(), "--help" | "-h"))
    {
        return Ok(Action::PrintCommandHelp {
            command: command.to_string_lossy().into_owned(),
        });
    }

    if command == OsString::from("help") {
        let _ = resolve_repo_root(repo_override)?;
        return Ok(Action::PrintHelp { with_header: true });
    }

    let backend_invocations = build_backend_invocations(
        repo_override,
        command_segments,
        command_validation,
        global_tail,
        global_compact,
    )?;
    Ok(Action::DispatchToBackend(backend_invocations))
}

fn parse_mcp_invocation(args: Vec<OsString>) -> Result<McpAction, String> {
    match args.as_slice() {
        [] => Ok(McpAction::RunServer),
        [arg] if matches!(arg.to_string_lossy().as_ref(), "--help" | "-h") => {
            Ok(McpAction::PrintHelp)
        }
        [arg] if arg == &OsString::from("--version") => Ok(McpAction::PrintVersion),
        [arg] => Err(format!(
            "Unknown makevn-mcp option: {}\nRun `makevn-mcp --help` for usage.",
            Lossy(arg)
        )),
        _ => Err(String::from(
            "makevn-mcp does not accept positional arguments. Run `makevn-mcp --help` for usage.",
        )),
    }
}

fn split_command_segments(args: Vec<OsString>) -> Result<Vec<(OsString, Vec<OsString>)>, String> {
    if args.is_empty() {
        return Ok(vec![(OsString::from("help"), Vec::new())]);
    }

    let mut segments = Vec::new();
    let mut current_command: Option<OsString> = None;
    let mut current_args = Vec::new();
    let mut forwarding_passthrough_args = false;
    let mut option_expects_value = false;

    for arg in args {
        if current_command.is_none() {
            current_command = Some(arg);
            continue;
        }

        if forwarding_passthrough_args {
            current_args.push(arg);
            continue;
        }

        if option_expects_value {
            current_args.push(arg);
            option_expects_value = false;
            continue;
        }

        if arg == OsString::from("--") {
            forwarding_passthrough_args = true;
            current_args.push(arg);
            continue;
        }

        if command_option_takes_value(&arg) {
            current_args.push(arg);
            option_expects_value = true;
            continue;
        }

        if current_command.as_ref() == Some(&OsString::from("make"))
            && current_args.is_empty()
            && (arg == OsString::from("install") || arg == OsString::from("uninstall"))
        {
            current_args.push(arg);
            continue;
        }

        if is_top_level_command(&arg)
            && !COMMAND_SEQUENCE_BREAKERS.contains(&arg.to_string_lossy().as_ref())
        {
            segments.push((current_command.take().unwrap(), current_args));
            current_command = Some(arg);
            current_args = Vec::new();
            continue;
        }

        current_args.push(arg);
    }

    segments.push((current_command.unwrap(), current_args));
    Ok(segments)
}

fn split_trailing_global_options(
    mut command_segments: Vec<(OsString, Vec<OsString>)>,
) -> (Vec<(OsString, Vec<OsString>)>, Vec<OsString>) {
    let Some((_, trailing_args)) = command_segments.last_mut() else {
        return (command_segments, Vec::new());
    };

    let mut global_options = Vec::new();
    while let Some(last_arg) = trailing_args.last() {
        if !is_global_option(last_arg) {
            break;
        }
        global_options.push(trailing_args.pop().unwrap());
    }
    global_options.reverse();

    (command_segments, global_options)
}

fn validate_command(
    command: &OsString,
    trailing_args: &[OsString],
) -> Result<CommandValidation, String> {
    if trailing_args
        .iter()
        .any(|arg| matches!(arg.to_string_lossy().as_ref(), "--help" | "-h"))
    {
        return Ok(CommandValidation::Valid);
    }

    match command.to_string_lossy().as_ref() {
        "compile" | "test-compile" | "compile-tests" | "validate" | "package" | "clean"
        | "build" | "verify-ut" | "verify-ut-coverage" | "verify-it" | "verify-it-coverage"
        | "verify" | "verify-changes-preview" | "verify-changes" | "pr-verify" | "format" | "checkstyle" | "karate-test"
        | "karate-all" | "mutation" => {
            validate_maven_passthrough_args(command, trailing_args)?;
            Ok(CommandValidation::Valid)
        }
        "help" | "init" | "refresh" | "uninstall" | "test" | "coverage" | "coverage-changes"
        | "docker-up" | "docker-down" | "docker-ps" | "docker-stats" | "docker-ps-required"
        | "karate-docker-up" | "karate-docker-down" | "run-app" | "run-app-bg" | "stop-app"
        | "run" => Ok(CommandValidation::Valid),
        "exec" => validate_exec_args(trailing_args),
        "doctor" => {
            if let Some(extra_arg) = trailing_args.first() {
                Err(format!("Unknown doctor option: {}", Lossy(extra_arg)))
            } else {
                Ok(CommandValidation::Valid)
            }
        }
        "make" => match trailing_args.first().map(|arg| arg.to_string_lossy()) {
            Some(subcommand) if subcommand == "install" || subcommand == "uninstall" => {
                Ok(CommandValidation::Valid)
            }
            _ => Err(String::from("Usage: makevn make install|uninstall")),
        },
        "profile" => match trailing_args.first().map(|arg| arg.to_string_lossy()) {
            Some(subcommand) if subcommand == "refresh" => Ok(CommandValidation::ProfileRefresh),
            _ => Err(String::from("Usage: makevn profile refresh")),
        },
        "jdk" => match trailing_args.first().map(|arg| arg.to_string_lossy()) {
            Some(subcommand) if subcommand == "current" || subcommand == "list" => {
                Ok(CommandValidation::JdkSubcommand)
            }
            _ => Err(String::from("Usage: makevn jdk current|list")),
        },
        _ => Err(format!("Unknown command: {}", Lossy(command))),
    }
}

fn validate_maven_passthrough_args(
    command: &OsString,
    trailing_args: &[OsString],
) -> Result<(), String> {
    let mut forwarding_passthrough_args = false;
    let mut previous_option_takes_value = false;

    for arg in trailing_args {
        if forwarding_passthrough_args {
            continue;
        }

        if arg == &OsString::from("--") {
            forwarding_passthrough_args = true;
            previous_option_takes_value = false;
            continue;
        }

        if arg == &OsString::from("--tail") {
            previous_option_takes_value = false;
            continue;
        }

        if previous_option_takes_value {
            previous_option_takes_value = false;
            continue;
        }

        let arg_text = arg.to_string_lossy();
        if arg_text.starts_with('-') {
            previous_option_takes_value =
                maven_option_takes_value(arg) || command_local_option_takes_value(command, arg);
            continue;
        }

        return Err(format!(
            "Unknown command: {}. Extra Maven arguments for {} must follow '--'.{}",
            Lossy(arg),
            Lossy(command),
            command_suggestion_suffix(arg)
        ));
    }

    Ok(())
}

fn command_local_option_takes_value(command: &OsString, arg: &OsString) -> bool {
    matches!(
        (
            command.to_string_lossy().as_ref(),
            arg.to_string_lossy().as_ref()
        ),
        ("karate-test" | "karate-all", "--tag")
    )
}

fn maven_option_takes_value(arg: &OsString) -> bool {
    matches!(
        arg.to_string_lossy().as_ref(),
        "-f" | "--file"
            | "-pl"
            | "--projects"
            | "-P"
            | "--activate-profiles"
            | "-s"
            | "--settings"
            | "-gs"
            | "--global-settings"
            | "-t"
            | "--toolchains"
            | "-rf"
            | "--resume-from"
            | "--module"
    )
}

fn command_suggestion_suffix(command: &OsString) -> String {
    match command.to_string_lossy().as_ref() {
        "verity-ut" => String::from(" Did you mean 'verify-ut'?"),
        "verity-it" => String::from(" Did you mean 'verify-it'?"),
        _ => String::new(),
    }
}

fn validate_exec_args(trailing_args: &[OsString]) -> Result<CommandValidation, String> {
    let Some(separator_index) = trailing_args.iter().position(|arg| arg == "--") else {
        return Err(String::from("exec requires '--' before the command"));
    };

    let delegated_args = &trailing_args[(separator_index + 1)..];
    let Some(delegated_command) = delegated_args.first() else {
        return Err(String::from("No command provided to exec"));
    };

    let command_text = delegated_command.to_string_lossy();
    if exec_command_is_allowed(command_text.as_ref()) {
        return Ok(CommandValidation::Valid);
    }

    Err(format!(
        "makevn exec only supports Maven, Java, or repo-local executable commands; use native agent shell tools for {}",
        Lossy(delegated_command)
    ))
}

fn exec_command_is_allowed(command: &str) -> bool {
    matches!(command, "mvn" | "mvnw" | "./mvnw" | "java") || command.starts_with("./")
}

fn build_backend_invocations(
    repo_override: Option<OsString>,
    command_segments: Vec<(OsString, Vec<OsString>)>,
    _command_validation: CommandValidation,
    global_tail_prefix: bool,
    global_compact_prefix: bool,
) -> Result<Vec<BackendInvocation>, String> {
    require_repo_path_is_git_root_for_strict_commands(repo_override.as_ref(), &command_segments)?;
    let repo_root = resolve_repo_root(repo_override)?;
    let (command_segments, global_options) = split_trailing_global_options(command_segments);
    let global_tail = global_tail_prefix
        || global_options
            .iter()
            .any(|arg| arg == &OsString::from("--tail"));
    let global_compact = global_compact_prefix
        || global_options
            .iter()
            .any(|arg| arg == &OsString::from("--compact"));
    let mut backend_invocations = Vec::with_capacity(command_segments.len());

    for (command, trailing_args) in command_segments {
        validate_command(&command, &trailing_args)?;
        let frontend_loader = command_supports_frontend_loader(&command);
        let (trailing_args, command_tail) = strip_frontend_tail_flag(&command, trailing_args)?;
        if global_tail && !frontend_loader {
            return Err(format!(
                "--tail is only supported for managed-log run commands, not {}",
                Lossy(&command)
            ));
        }
        let tail = command_tail || (global_tail && frontend_loader);
        let mut backend_args = Vec::with_capacity(trailing_args.len() + 3);
        backend_args.push(command);
        backend_args.push(OsString::from("--repo"));
        backend_args.push(repo_root.clone().into_os_string());
        if global_compact {
            backend_args.push(OsString::from("--compact"));
        }
        backend_args.extend(trailing_args);
        backend_invocations.push(BackendInvocation {
            args: backend_args,
            frontend_loader,
            tail,
            compact: global_compact,
        });
    }

    Ok(backend_invocations)
}

fn is_top_level_command(arg: &OsString) -> bool {
    matches!(
        arg.to_string_lossy().as_ref(),
        "help"
            | "doctor"
            | "init"
            | "make"
            | "uninstall"
            | "profile"
            | "exec"
            | "compile"
            | "test-compile"
            | "compile-tests"
            | "validate"
            | "package"
            | "clean"
            | "build"
            | "test"
            | "verify-ut"
            | "verify-ut-coverage"
            | "verify-it"
            | "verify-it-coverage"
            | "verify"
            | "verify-changes-preview"
            | "verify-changes"
            | "coverage"
            | "coverage-changes"
            | "pr-verify"
            | "format"
            | "checkstyle"
            | "docker-up"
            | "docker-down"
            | "docker-ps"
            | "docker-stats"
            | "docker-ps-required"
            | "karate-docker-up"
            | "karate-docker-down"
            | "karate-test"
            | "karate-all"
            | "run-app"
            | "run-app-bg"
            | "stop-app"
            | "run"
            | "jdk"
            | "mutation"
    )
}

fn command_option_takes_value(arg: &OsString) -> bool {
    matches!(
        arg.to_string_lossy().as_ref(),
        "--name" | "--context" | "--threshold" | "--tag" | "--compose" | "--module"
    )
}

fn is_global_option(arg: &OsString) -> bool {
    matches!(arg.to_string_lossy().as_ref(), "--tail" | "--compact")
}

fn strip_frontend_tail_flag(
    command: &OsString,
    trailing_args: Vec<OsString>,
) -> Result<(Vec<OsString>, bool), String> {
    let mut forwarded_args = Vec::with_capacity(trailing_args.len());
    let mut tail = false;
    let mut forwarding_passthrough_args = false;

    for arg in trailing_args {
        if forwarding_passthrough_args {
            forwarded_args.push(arg);
            continue;
        }

        if arg == OsString::from("--") {
            forwarding_passthrough_args = true;
            forwarded_args.push(arg);
            continue;
        }

        if arg == OsString::from("--tail") {
            if !command_supports_frontend_loader(command) {
                return Err(format!(
                    "--tail is only supported for managed-log run commands, not {}",
                    Lossy(command)
                ));
            }
            tail = true;
            continue;
        }

        forwarded_args.push(arg);
    }

    Ok((forwarded_args, tail))
}

impl BackendMetadataFile {
    fn new() -> Result<Self, String> {
        let unique_suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| format!("failed to resolve metadata timestamp: {error}"))?
            .as_nanos();
        let path = env::temp_dir().join(format!("makevn-{}-{unique_suffix}.meta", process::id()));
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for BackendMetadataFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn insert_backend_option(args: &mut Vec<OsString>, flag: &str, value: OsString) {
    let insert_at = args
        .iter()
        .position(|arg| arg == "--")
        .unwrap_or(args.len());
    args.insert(insert_at, OsString::from(flag));
    args.insert(insert_at + 1, value);
}

fn command_supports_frontend_loader(command: &OsString) -> bool {
    matches!(
        command.to_string_lossy().as_ref(),
        "compile"
            | "test-compile"
            | "compile-tests"
            | "validate"
            | "package"
            | "build"
            | "clean"
            | "test"
            | "verify-ut"
            | "verify-ut-coverage"
            | "verify-it"
            | "verify-it-coverage"
            | "verify"
            | "verify-changes-preview"
            | "verify-changes"
            | "coverage"
            | "coverage-changes"
            | "pr-verify"
            | "format"
            | "checkstyle"
            | "docker-up"
            | "docker-down"
            | "docker-ps"
            | "docker-stats"
            | "docker-ps-required"
            | "karate-docker-up"
            | "karate-docker-down"
            | "karate-test"
            | "karate-all"
            | "run-app"
            | "mutation"
    )
}

fn frontend_loader_is_available() -> bool {
    io::stdin().is_terminal() && io::stdout().is_terminal()
}

fn dispatch_backend_invocations(
    backend_path: &Path,
    current_exe: &Path,
    install_root: &Path,
    backend_invocations: Vec<BackendInvocation>,
) -> Result<i32, String> {
    let mut last_exit_code = 0;
    let started_at = Instant::now();
    let mut completed_summaries: Vec<CommandSummary> = Vec::new();
    let compact_output = backend_invocations
        .iter()
        .any(|invocation| invocation.compact);
    if compact_output {
        env::set_var("NO_COLOR", "1");
    }
    let use_dashboard = backend_invocations
        .iter()
        .any(|invocation| invocation.frontend_loader && !invocation.compact);

    // Create the renderer and detail file once for the entire run so there is
    // a single continuous spinner and a single "Working for" counter.
    let loader_available = use_dashboard && frontend_loader_is_available();
    let detail_file = if loader_available {
        BackendDetailFile::new().ok()
    } else {
        None
    };
    let mut renderer = if loader_available {
        SpinnerRenderer::new().ok()
    } else {
        None
    };

    for mut backend_invocation in backend_invocations {
        let fallback_title = backend_invocation
            .args
            .first()
            .map(|arg| arg.to_string_lossy().into_owned())
            .unwrap_or_else(|| String::from("command"));
        let use_frontend_loader = backend_invocation.frontend_loader
            && !backend_invocation.compact
            && frontend_loader_is_available();
        let metadata_file = if use_frontend_loader {
            let metadata_file = BackendMetadataFile::new()?;
            insert_backend_option(
                &mut backend_invocation.args,
                "--metadata-out",
                metadata_file.path().as_os_str().to_os_string(),
            );
            Some(metadata_file)
        } else {
            None
        };

        let mut command = process::Command::new("bash");
        command.arg(backend_path);
        command.args(&backend_invocation.args);
        command.process_group(0);
        command.env("MAKEVN_BIN_PATH", current_exe);
        command.env("MAKEVN_INSTALL_ROOT", install_root);
        command.env("MAKEVN_FRONTEND", "rust");
        command.env("MAKEVN_FRONTEND_VERSION", makevn_version());
        command.env("MAKEVN_VERSION", makevn_version());

        let run_result = if use_frontend_loader {
            command.stdout(process::Stdio::null());
            command.env("MAKEVN_FRONTEND_OWNS_LOADER", "1");
            if let Some(df) = detail_file.as_ref() {
                command.env("MAKEVN_BACKEND_DETAIL_OUT", df.path());
            }
            run_backend_with_loader(
                command,
                metadata_file.as_ref(),
                backend_invocation.tail,
                &fallback_title,
                started_at,
                &completed_summaries,
                renderer.as_mut(),
                detail_file.as_ref(),
            )?
        } else {
            let elapsed_before = started_at.elapsed();
            let exit_code = run_backend_command(command, backend_path)?;
            BackendRunResult {
                exit_code,
                summary: CommandSummary {
                    title: fallback_title.clone(),
                    duration: format_duration(started_at.elapsed().saturating_sub(elapsed_before)),
                    log_path: None,
                    relative_log_path: None,
                    exit_code,
                    detail_lines: Vec::new(),
                },
            }
        };

        // Snapshot detail lines into the summary then clear for the next command.
        let detail_lines = detail_file
            .as_ref()
            .map(|df| df.read_lines())
            .unwrap_or_default();
        if let Some(df) = detail_file.as_ref() {
            df.clear();
        }

        last_exit_code = run_result.exit_code;
        let failure_hint = read_failure_hint(run_result.summary.log_path.as_deref());
        let mut summary = run_result.summary;
        summary.detail_lines = detail_lines;
        completed_summaries.push(summary);

        if last_exit_code != 0 {
            if let Some(r) = renderer.as_mut() {
                r.clear_line();
                r.show_cursor();
            }
            if backend_invocation.tail && last_exit_code == 130 {
                return Ok(last_exit_code);
            }
            if use_dashboard {
                print_final_dashboard(started_at.elapsed(), &completed_summaries, false)
                    .map_err(|error| format!("failed to print run summary: {error}"))?;
                let _ = writeln!(
                    io::stdout(),
                    "[{}]{}",
                    warn_text("fail"),
                    dim_text(&format_failure_summary(
                        last_exit_code,
                        None,
                        failure_hint.as_deref(),
                    ))
                );
            } else {
                let duration = format_duration(started_at.elapsed());
                let _ = writeln!(
                    io::stdout(),
                    "[{}]{}",
                    warn_text("fail"),
                    dim_text(&format_failure_summary(
                        last_exit_code,
                        Some(duration.as_str()),
                        failure_hint.as_deref(),
                    ))
                );
            }
            return Ok(last_exit_code);
        }
    }

    if let Some(r) = renderer.as_mut() {
        r.clear_line();
        r.show_cursor();
    }
    if use_dashboard {
        print_final_dashboard(started_at.elapsed(), &completed_summaries, true)
            .map_err(|error| format!("failed to print run summary: {error}"))?;
    } else {
        let duration = format_duration(started_at.elapsed());
        let _ = writeln!(
            io::stdout(),
            "[{}]{}",
            style("32", "ok"),
            dim_text(&format!(" {duration}"))
        );
    }
    Ok(last_exit_code)
}

fn format_failure_summary(
    exit_code: i32,
    duration: Option<&str>,
    failure_hint: Option<&str>,
) -> String {
    let mut summary = format!(" exit {exit_code}");
    if let Some(duration) = duration {
        summary.push_str(&format!(" | {duration}"));
    }
    if let Some(hint) = failure_hint.filter(|hint| !hint.is_empty()) {
        summary.push_str(" | ");
        summary.push_str(hint);
    } else {
        summary.push_str(" | check the log");
    }
    summary
}

fn read_failure_hint(log_path: Option<&str>) -> Option<String> {
    let content = fs::read_to_string(log_path?).ok()?;
    for line in content.lines() {
        let trimmed = line.trim();
        if let Some(error) = trimmed.strip_prefix("Error: ") {
            return Some(error.to_owned());
        }
    }
    None
}

fn run_backend_command(mut command: process::Command, backend_path: &Path) -> Result<i32, String> {
    let status = command.status().map_err(|error| {
        format!(
            "failed to launch backend {}: {error}",
            backend_path.display()
        )
    })?;
    Ok(exit_code_from_status(status, false))
}

fn run_backend_with_loader(
    mut command: process::Command,
    metadata_file: Option<&BackendMetadataFile>,
    tail_enabled: bool,
    fallback_title: &str,
    global_started_at: Instant,
    completed_summaries: &[CommandSummary],
    mut renderer: Option<&mut SpinnerRenderer>,
    detail_file: Option<&BackendDetailFile>,
) -> Result<BackendRunResult, String> {
    let started_at = Instant::now();
    let mut child = command.spawn().map_err(|error| {
        format!(
            "failed to launch backend {}: {error}",
            command.get_program().to_string_lossy()
        )
    })?;

    let signal_requested = Arc::new(AtomicBool::new(false));
    #[cfg(unix)]
    register_signal_flag(&signal_requested)?;

    let mut cancel_requested = false;
    let mut cancel_requested_at: Option<Instant> = None;
    let mut header_printed = false;
    let mut tail_window = None;
    let mut tail_active = tail_enabled;
    let mut metadata = if let Some(metadata_file) = metadata_file {
        read_backend_metadata(metadata_file.path())?
    } else {
        None
    };
    let mut current_detail_lines: Vec<String> = Vec::new();

    if metadata.is_none() {
        for _ in 0..3 {
            let Some(metadata_file) = metadata_file else {
                break;
            };
            metadata = read_backend_metadata(metadata_file.path())?;
            if metadata.is_some() {
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
    }

    if let Some(metadata) = metadata.as_ref() {
        if let Some(renderer) = renderer.as_mut() {
            renderer.clear_frame_line();
        }
        if tail_active {
            tail_window = Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
        } else if let Some(renderer) = renderer.as_mut() {
            if let Some(df) = detail_file {
                current_detail_lines = df.read_lines();
            }
            let hint = renderer.current_dashboard_hint();
            renderer
                .render_dashboard(
                    child.id(),
                    global_started_at.elapsed(),
                    completed_summaries,
                    &current_detail_lines,
                    metadata,
                    &hint,
                )
                .map_err(|error| format!("failed to render loader: {error}"))?;
        }
        header_printed = true;
    }

    loop {
        if let Some(metadata_file) = metadata_file {
            let latest_metadata = read_backend_metadata(metadata_file.path())?;
            if latest_metadata.is_some() && latest_metadata != metadata {
                metadata = latest_metadata;
                if let Some(renderer) = renderer.as_mut() {
                    renderer.clear_frame_line();
                }
                if tail_active {
                    if let Some(metadata) = metadata.as_ref() {
                        tail_window = Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
                    }
                }
            }
        }

        if let Some(df) = detail_file {
            let latest = df.read_lines();
            if latest.len() != current_detail_lines.len() {
                current_detail_lines = latest;
            }
        }

        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("failed while waiting for backend: {error}"))?
        {
            if let Some(metadata_file) = metadata_file {
                if let Some(latest_metadata) = read_backend_metadata(metadata_file.path())? {
                    metadata = Some(latest_metadata);
                }
            }
            if !header_printed {
                if metadata.is_none() {
                    if let Some(metadata_file) = metadata_file {
                        metadata = read_backend_metadata(metadata_file.path())?;
                    }
                }
                if let Some(metadata) = metadata.as_ref() {
                    if let Some(renderer) = renderer.as_mut() {
                        renderer.clear_frame_line();
                    }
                    if tail_active {
                        tail_window = Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
                    } else if let Some(renderer) = renderer.as_mut() {
                        let hint = renderer.current_dashboard_hint();
                        renderer
                            .render_dashboard(
                                child.id(),
                                global_started_at.elapsed(),
                                completed_summaries,
                                &current_detail_lines,
                                metadata,
                                &hint,
                            )
                            .map_err(|error| format!("failed to render loader: {error}"))?;
                    }
                }
            }
            if let Some(tail_window) = tail_window.as_mut() {
                if let Some(metadata) = metadata.as_ref() {
                    tail_window.set_prefix_lines(tail_status_lines(
                        global_started_at.elapsed(),
                        completed_summaries,
                        metadata,
                    ));
                }
                tail_window.set_loader_line(None);
                if !cancel_requested {
                    tail_window
                        .finish()
                        .map_err(|error| format!("failed to render tailed log: {error}"))?;
                }
                if tail_active {
                    tail_window
                        .clear()
                        .map_err(|error| format!("failed to clear tailed log: {error}"))?;
                }
            }
            if let Some(renderer) = renderer.as_mut() {
                renderer.clear_line();
            }
            return Ok(summarize_backend_exit(
                status,
                started_at.elapsed(),
                cancel_requested || signal_requested.load(Ordering::Relaxed),
                metadata.as_ref(),
                fallback_title,
            ));
        }

        if signal_requested.load(Ordering::Relaxed) {
            if !cancel_requested {
                interrupt_backend(child.id());
                cancel_requested = true;
                cancel_requested_at = Some(Instant::now());
            }
        }

        if let Some(requested_at) = cancel_requested_at {
            let elapsed = requested_at.elapsed();
            if elapsed > Duration::from_secs(4) {
                let _ = unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL) };
                break;
            } else if elapsed > Duration::from_secs(2) {
                let _ = unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGTERM) };
            }
        }

        if !header_printed {
            if metadata.is_none() {
                if let Some(metadata_file) = metadata_file {
                    metadata = read_backend_metadata(metadata_file.path())?;
                }
            }

            if let Some(metadata) = metadata.as_ref() {
                if let Some(renderer) = renderer.as_mut() {
                    renderer.clear_frame_line();
                }
                if tail_active {
                    tail_window = Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
                } else if let Some(renderer) = renderer.as_mut() {
                    let hint = renderer.current_dashboard_hint();
                    renderer
                        .render_dashboard(
                            child.id(),
                            global_started_at.elapsed(),
                            completed_summaries,
                            &current_detail_lines,
                            metadata,
                            &hint,
                        )
                        .map_err(|error| format!("failed to render loader: {error}"))?;
                }
                header_printed = true;
                continue;
            }
        }

        let mut line_delta: i32 = 0;
        if let Some(renderer) = renderer.as_mut() {
            match renderer
                .poll_input()
                .map_err(|error| format!("failed to read terminal input: {error}"))?
            {
                InputEvent::Interrupt => {
                    interrupt_backend(child.id());
                    #[cfg(unix)]
                    unsafe {
                        libc::kill(-(child.id() as libc::pid_t), SIGTERM);
                    }
                    cancel_requested = true;
                    cancel_requested_at = Some(Instant::now());
                }
                InputEvent::StartTail => {
                    if !tail_active {
                        if let Some(metadata) = metadata.as_ref() {
                            renderer.clear_frame_line();
                            tail_window =
                                Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
                            tail_active = true;
                        }
                    }
                }
                InputEvent::IncreaseLines => line_delta = 1,
                InputEvent::DecreaseLines => line_delta = -1,
                InputEvent::None => {}
            }
        }

        if let Some(tail_window) = tail_window.as_mut() {
            if let Some(metadata) = metadata.as_ref() {
                tail_window.set_prefix_lines(tail_status_lines(
                    global_started_at.elapsed(),
                    completed_summaries,
                    metadata,
                ));
            }
            if line_delta != 0 {
                tail_window.adjust_lines(line_delta);
            }
            if let Some(renderer) = renderer.as_mut() {
                let interrupt_hint = renderer.current_spinner_hint();
                let frame_line = renderer
                    .frame_line_with_hint(child.id(), &tail_hint(&interrupt_hint))
                    .map_err(|error| format!("failed to render loader: {error}"))?;
                tail_window.set_loader_line(Some(frame_line));
            }
            tail_window
                .refresh()
                .map_err(|error| format!("failed to render tailed log: {error}"))?;
            if renderer.is_none() {
                thread::sleep(Duration::from_millis(100));
            }
            continue;
        }

        if let Some(renderer) = renderer.as_mut() {
            match metadata.as_ref() {
                Some(m) if !tail_active => {
                    let hint = renderer.current_dashboard_hint();
                    renderer
                        .render_dashboard(
                            child.id(),
                            global_started_at.elapsed(),
                            completed_summaries,
                            &current_detail_lines,
                            m,
                            &hint,
                        )
                        .map_err(|error| format!("failed to render loader: {error}"))?
                }
                _ => {
                    let hint = renderer.current_spinner_hint();
                    if completed_summaries.is_empty() {
                        renderer
                            .render_frame_with_hint(child.id(), &hint)
                            .map_err(|error| format!("failed to render loader: {error}"))?;
                    } else {
                        thread::sleep(Duration::from_millis(50));
                    }
                }
            }
        } else {
            thread::sleep(Duration::from_millis(100));
        }
    }

    if let Some(tail_window) = tail_window.as_mut() {
        if let Some(metadata) = metadata.as_ref() {
            tail_window.set_prefix_lines(tail_status_lines(
                global_started_at.elapsed(),
                completed_summaries,
                metadata,
            ));
        }
        tail_window.set_loader_line(None);
        if !cancel_requested && !signal_requested.load(Ordering::Relaxed) {
            tail_window
                .finish()
                .map_err(|error| format!("failed to render tailed log: {error}"))?;
        }
        if tail_active {
            tail_window
                .clear()
                .map_err(|error| format!("failed to clear tailed log: {error}"))?;
        }
    }

    if let Some(renderer) = renderer.as_mut() {
        renderer.clear_line();
    }

    let status = child
        .wait()
        .map_err(|error| format!("failed while waiting for backend: {error}"))?;
    Ok(summarize_backend_exit(
        status,
        started_at.elapsed(),
        cancel_requested || signal_requested.load(Ordering::Relaxed),
        metadata.as_ref(),
        fallback_title,
    ))
}

fn read_backend_metadata(metadata_path: &Path) -> Result<Option<BackendMetadata>, String> {
    let content = match fs::read_to_string(metadata_path) {
        Ok(content) => content,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "failed to read backend metadata {}: {error}",
                metadata_path.display()
            ))
        }
    };

    let mut command = None;
    let mut repo = None;
    let mut cwd = None;
    let mut log_path = None;
    let mut relative_log_path = None;
    let mut command_display = None;
    let mut title = None;
    let mut context = None;

    for line in content.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "command" => command = Some(value.to_owned()),
            "repo" => repo = Some(value.to_owned()),
            "cwd" => cwd = Some(value.to_owned()),
            "log_path" => log_path = Some(value.to_owned()),
            "relative_log_path" => relative_log_path = Some(value.to_owned()),
            "command_display" => command_display = Some(value.to_owned()),
            "title" => title = Some(value.to_owned()),
            "context" => context = Some(value.to_owned()),
            _ => {}
        }
    }

    let (
        Some(command),
        Some(repo),
        Some(cwd),
        Some(log_path),
        Some(relative_log_path),
        Some(command_display),
        Some(title),
    ) = (
        command,
        repo,
        cwd,
        log_path,
        relative_log_path,
        command_display,
        title,
    )
    else {
        return Ok(None);
    };

    Ok(Some(BackendMetadata {
        command,
        repo,
        cwd,
        log_path,
        relative_log_path,
        command_display,
        title,
        context,
    }))
}

fn backend_header_line(metadata: &BackendMetadata) -> String {
    format!(
        "{} {}",
        dim_text("::"),
        accent_text(&format!("makevn {}", metadata.title))
    )
}

fn backend_tail_notice_line(metadata: &BackendMetadata) -> String {
    dim_text(&format!(" └ tailing log: {}", metadata.relative_log_path))
}

fn print_final_dashboard(
    elapsed: Duration,
    completed_summaries: &[CommandSummary],
    success: bool,
) -> io::Result<()> {
    for line in final_dashboard_lines(elapsed, completed_summaries, success) {
        writeln!(io::stdout(), "{line}")?;
    }
    Ok(())
}

fn final_dashboard_lines(
    elapsed: Duration,
    completed_summaries: &[CommandSummary],
    success: bool,
) -> Vec<String> {
    let mut lines = Vec::with_capacity(
        1 + completed_summaries
            .iter()
            .map(|summary| 1 + summary.detail_lines.len())
            .sum::<usize>()
            + usize::from(success),
    );
    lines.push(dim_text(&format!(
        "Worked for {}",
        format_duration(elapsed)
    )));
    for summary in completed_summaries {
        lines.push(completed_summary_line(summary));
        for dl in &summary.detail_lines {
            lines.push(detail_line(dl));
        }
    }
    if success {
        lines.push(format!("[{}]", style("32", "ok")));
    }
    lines
}

fn detail_line(text: &str) -> String {
    if text.is_empty()
        || text.starts_with('┌')
        || text.starts_with('├')
        || text.starts_with('└')
        || text.starts_with('│')
    {
        return dim_text(text);
    }
    format!("{} {}", dim_text("│"), dim_text(text))
}

fn completed_summary_line(summary: &CommandSummary) -> String {
    let mark = if summary.exit_code == 0 {
        accent_text("✓")
    } else {
        warn_text("x")
    };
    let rest = match summary.relative_log_path.as_deref() {
        Some(log_path) => format!(" {} | {} | {}", summary.title, summary.duration, log_path),
        None => format!(" {} | {}", summary.title, summary.duration),
    };

    format!("[{}]{}", mark, dim_text(&rest))
}

fn completed_summary_lines(completed_summaries: &[CommandSummary]) -> Vec<String> {
    let mut lines = Vec::new();
    for summary in completed_summaries {
        lines.push(completed_summary_line(summary));
        for dl in &summary.detail_lines {
            lines.push(detail_line(dl));
        }
    }
    lines
}

fn tail_status_lines(
    global_elapsed: Duration,
    completed_summaries: &[CommandSummary],
    metadata: &BackendMetadata,
) -> Vec<String> {
    let mut lines = Vec::new();
    lines.push(dim_text(&format!(
        "Working for {} >",
        format_duration(global_elapsed)
    )));
    lines.extend(completed_summary_lines(completed_summaries));
    lines.push(backend_header_line(metadata));
    lines.push(backend_tail_notice_line(metadata));
    lines
}

fn running_command_line(metadata: &BackendMetadata) -> String {
    if metadata.relative_log_path.is_empty() {
        format!(
            "{} {}",
            dim_text("->"),
            accent_text(&format!("makevn {}", metadata.title))
        )
    } else {
        format!(
            "{} {} {} {}",
            dim_text("::"),
            accent_text(&format!("makevn {}", metadata.title)),
            dim_text("|"),
            dim_text(&metadata.relative_log_path)
        )
    }
}

#[cfg(unix)]
fn register_signal_flag(signal_requested: &Arc<AtomicBool>) -> Result<(), String> {
    signal_hook::flag::register(SIGINT, Arc::clone(signal_requested))
        .map_err(|error| format!("failed to register SIGINT handler: {error}"))?;
    signal_hook::flag::register(SIGTERM, Arc::clone(signal_requested))
        .map_err(|error| format!("failed to register SIGTERM handler: {error}"))?;
    Ok(())
}

#[cfg(not(unix))]
fn register_signal_flag(_signal_requested: &Arc<AtomicBool>) -> Result<(), String> {
    Ok(())
}

fn summarize_backend_exit(
    status: process::ExitStatus,
    elapsed: Duration,
    interrupted: bool,
    metadata: Option<&BackendMetadata>,
    fallback_title: &str,
) -> BackendRunResult {
    let exit_code = exit_code_from_status(status, interrupted);
    let duration = format_duration(elapsed);
    let title = metadata.map(|m| m.title.as_str()).unwrap_or(fallback_title);
    let relative_log_path = metadata.and_then(|m| {
        if m.relative_log_path.is_empty() {
            None
        } else {
            Some(m.relative_log_path.clone())
        }
    });

    BackendRunResult {
        exit_code,
        summary: CommandSummary {
            title: title.to_owned(),
            duration,
            log_path: metadata.map(|m| m.log_path.clone()),
            relative_log_path,
            exit_code,
            detail_lines: Vec::new(), // populated by dispatch_backend_invocations
        },
    }
}

fn exit_code_from_status(status: process::ExitStatus, interrupted: bool) -> i32 {
    if interrupted {
        return 130;
    }

    if let Some(code) = status.code() {
        return code;
    }

    #[cfg(unix)]
    {
        if status.signal() == Some(SIGINT) || status.signal() == Some(SIGTERM) {
            return 130;
        }
    }

    1
}

fn interrupt_backend(pid: u32) {
    #[cfg(unix)]
    unsafe {
        libc::kill(-(pid as libc::pid_t), SIGINT);
    }
}

fn format_duration(elapsed: Duration) -> String {
    let total_seconds = elapsed.as_secs();
    if total_seconds < 60 {
        return format!("{total_seconds}s");
    }

    let minutes = total_seconds / 60;
    let seconds = total_seconds % 60;
    format!("{minutes}m {seconds:02}s")
}

fn use_color() -> bool {
    if agent_output_mode() {
        return false;
    }

    (io::stdout().is_terminal() || io::stderr().is_terminal())
        && env::var_os("NO_COLOR").is_none()
        && env::var("TERM").map(|term| term != "dumb").unwrap_or(true)
}

fn agent_output_mode() -> bool {
    env::var_os("MAKEVN_COMPACT_OUTPUT").is_some() || env::var_os("MAKEVN_AGENT_OUTPUT").is_some()
}

fn style(code: &str, text: &str) -> String {
    if use_color() {
        format!("\u{1b}[{code}m{text}\u{1b}[0m")
    } else {
        text.to_owned()
    }
}

fn terminal_width() -> usize {
    terminal_width_from_tty()
        .or_else(|| terminal_width_from_columns(env::var("COLUMNS").ok().as_deref()))
        .unwrap_or(120)
}

fn terminal_width_from_columns(columns: Option<&str>) -> Option<usize> {
    columns
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
}

fn terminal_width_from_tty() -> Option<usize> {
    let stdout = io::stdout();
    if stdout.is_terminal() {
        if let Some(width) = terminal_width_from_fd(stdout.as_raw_fd()) {
            return Some(width);
        }
    }

    let stderr = io::stderr();
    if stderr.is_terminal() {
        if let Some(width) = terminal_width_from_fd(stderr.as_raw_fd()) {
            return Some(width);
        }
    }

    let stdin = io::stdin();
    if stdin.is_terminal() {
        return terminal_width_from_fd(stdin.as_raw_fd());
    }

    None
}

fn terminal_width_from_fd(fd: i32) -> Option<usize> {
    let mut size = MaybeUninit::<libc::winsize>::zeroed();
    let result = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, size.as_mut_ptr()) };
    if result != 0 {
        return None;
    }

    let size = unsafe { size.assume_init() };
    let width = usize::from(size.ws_col);
    (width > 0).then_some(width)
}

fn dim_text(text: &str) -> String {
    style("90", text)
}

fn faint_text(text: &str) -> String {
    style("2;90", text)
}

fn accent_text(text: &str) -> String {
    style("36", text)
}

fn warn_text(text: &str) -> String {
    style("33", text)
}

fn adaptive_metric_text(text: &str, load: f32) -> String {
    if !use_color() {
        return text.to_owned();
    }

    let cool = Rgb::new(96, 165, 250);
    let warm = Rgb::new(214, 93, 63);
    style(&rgb_code(interpolate_color(cool, warm, load)), text)
}

fn cpu_metric_load(sample: &ResourceSample) -> f32 {
    (sample.cpu_percent / 250.0).clamp(0.0, 1.0)
}

fn ram_metric_load(sample: &ResourceSample) -> f32 {
    const KIB_PER_GIB: f32 = 1024.0 * 1024.0;
    (sample.rss_kb as f32 / (2.5 * KIB_PER_GIB)).clamp(0.0, 1.0)
}

fn spinner_hint(message: &str) -> String {
    if use_color() {
        let suffix = if message == "again to interrupt" {
            style("94", message)
        } else {
            dim_text(message)
        };
        return format!("{} {}", style("97", "esc"), suffix);
    }

    format!("esc {message}")
}

fn dashboard_hint(interrupt_hint: &str) -> String {
    if use_color() {
        return format!(
            "{} {} {}",
            style("97", "t"),
            dim_text("tail |"),
            interrupt_hint
        );
    }

    format!("t tail | {interrupt_hint}")
}

fn tail_hint(interrupt_hint: &str) -> String {
    if use_color() {
        format!(
            "{} {} {}",
            style("97", "+/-"),
            dim_text("lines |"),
            interrupt_hint
        )
    } else {
        format!("+/- lines | {interrupt_hint}")
    }
}

fn tail_line_text_for_width(line: &str, width: usize) -> String {
    let max_chars = width.saturating_sub(1);
    faint_text(&truncate_plain_line(line, max_chars))
}

fn status_line_text_for_width(line: &str, width: usize) -> String {
    let max_chars = width.saturating_sub(1);
    truncate_ansi_line(line, max_chars)
}

fn truncate_plain_line(line: &str, max_chars: usize) -> String {
    let mut truncated = String::new();
    let mut count = 0usize;

    for ch in line.chars() {
        if count >= max_chars {
            break;
        }
        truncated.push(ch);
        count += 1;
    }

    if line.chars().count() > max_chars && max_chars > 0 {
        truncated.pop();
        truncated.push('~');
    }

    truncated
}

fn truncate_ansi_line(line: &str, max_chars: usize) -> String {
    if visible_char_count(line) <= max_chars {
        return line.to_owned();
    }

    if max_chars == 0 {
        return String::new();
    }

    let mut truncated = String::new();
    let mut chars = line.chars().peekable();
    let mut visible_count = 0usize;
    let visible_limit = max_chars.saturating_sub(1);

    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            truncated.push(ch);
            copy_ansi_sequence(&mut chars, &mut truncated);
            continue;
        }

        if visible_count >= visible_limit {
            break;
        }

        truncated.push(ch);
        visible_count += 1;
    }

    truncated.push('~');
    if use_color() {
        truncated.push_str("\u{1b}[0m");
    }
    truncated
}

fn visible_char_count(line: &str) -> usize {
    let mut chars = line.chars().peekable();
    let mut count = 0usize;

    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            skip_ansi_sequence(&mut chars);
            continue;
        }

        count += 1;
    }

    count
}

fn copy_ansi_sequence<I>(chars: &mut std::iter::Peekable<I>, output: &mut String)
where
    I: Iterator<Item = char>,
{
    if matches!(chars.peek(), Some('[')) {
        output.push(chars.next().expect("peeked CSI introducer"));
        while let Some(next) = chars.next() {
            output.push(next);
            if ('@'..='~').contains(&next) {
                break;
            }
        }
        return;
    }

    if let Some(next) = chars.next() {
        output.push(next);
    }
}

fn skip_ansi_sequence<I>(chars: &mut std::iter::Peekable<I>)
where
    I: Iterator<Item = char>,
{
    if matches!(chars.peek(), Some('[')) {
        chars.next();
        while let Some(next) = chars.next() {
            if ('@'..='~').contains(&next) {
                break;
            }
        }
        return;
    }

    chars.next();
}

struct LogTailWindow {
    path: PathBuf,
    prefix_lines: Vec<String>,
    loader_line: Option<String>,
    file: Option<File>,
    offset: u64,
    pending: Vec<u8>,
    lines: Vec<String>,
    visible_lines: usize,
    rendered_lines: usize,
    rendered_width: usize,
    rendered_line_widths: Vec<usize>,
}

impl LogTailWindow {
    fn new(path: PathBuf) -> Self {
        Self {
            path,
            prefix_lines: Vec::new(),
            loader_line: None,
            file: None,
            offset: 0,
            pending: Vec::new(),
            lines: Vec::new(),
            visible_lines: 4,
            rendered_lines: 0,
            rendered_width: terminal_width().max(8),
            rendered_line_widths: Vec::new(),
        }
    }

    fn set_prefix_lines(&mut self, prefix_lines: Vec<String>) {
        self.prefix_lines = prefix_lines;
    }

    fn set_loader_line(&mut self, loader_line: Option<String>) {
        self.loader_line = loader_line;
    }

    fn adjust_lines(&mut self, delta: i32) {
        self.visible_lines = (self.visible_lines as i32 + delta).clamp(1, 20) as usize;
    }

    fn refresh(&mut self) -> io::Result<()> {
        self.read_available()?;
        self.render()
    }

    fn finish(&mut self) -> io::Result<()> {
        self.read_available()?;
        if !self.pending.is_empty() {
            self.push_line(String::from_utf8_lossy(&self.pending).into_owned());
            self.pending.clear();
        }
        self.render()
    }

    fn read_available(&mut self) -> io::Result<()> {
        if self.file.is_none() {
            match File::open(&self.path) {
                Ok(file) => self.file = Some(file),
                Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
                Err(error) => return Err(error),
            }
        }

        let Some(file) = self.file.as_mut() else {
            return Ok(());
        };

        let file_len = file.metadata()?.len();
        if file_len < self.offset {
            self.offset = 0;
            self.pending.clear();
            self.lines.clear();
        }

        let mut new_lines = Vec::new();
        file.seek(SeekFrom::Start(self.offset))?;
        let mut chunk = [0_u8; 8192];
        loop {
            match file.read(&mut chunk) {
                Ok(0) => break,
                Ok(read_bytes) => {
                    self.offset += read_bytes as u64;
                    self.pending.extend_from_slice(&chunk[..read_bytes]);
                    while let Some(line_end) = self.pending.iter().position(|byte| *byte == b'\n') {
                        let line = self.pending.drain(..=line_end).collect::<Vec<_>>();
                        let line = String::from_utf8_lossy(&line)
                            .trim_end_matches('\n')
                            .trim_end_matches('\r')
                            .to_owned();
                        new_lines.push(line);
                    }
                }
                Err(error) => return Err(error),
            }
        }

        for line in new_lines {
            self.push_line(line);
        }

        Ok(())
    }

    fn push_line(&mut self, line: String) {
        self.lines.push(line);
        let max_lines = self.max_lines();
        if self.lines.len() > max_lines {
            let drop_count = self.lines.len() - max_lines;
            self.lines.drain(..drop_count);
        }
    }

    fn max_lines(&self) -> usize {
        self.visible_lines
    }

    fn render(&mut self) -> io::Result<()> {
        let visible_capacity = self.max_lines();
        if self.lines.len() > visible_capacity {
            let drop_count = self.lines.len() - visible_capacity;
            self.lines.drain(..drop_count);
        }

        let render_width = terminal_width().max(8);
        let output_lines = self.rendered_output_lines(render_width, visible_capacity);
        let previous_rows = physical_rows_for_width(&self.rendered_line_widths, render_width);
        let clear_rows = previous_rows.max(output_lines.len()) + usize::from(previous_rows > 0);

        if previous_rows > 0 {
            write!(io::stdout(), "\u{1b}[{}A", previous_rows)?;
        }

        for index in 0..clear_rows {
            write!(io::stdout(), "\r\u{1b}[2K")?;
            if index + 1 < clear_rows {
                write!(io::stdout(), "\n")?;
            }
        }

        if clear_rows > 1 {
            write!(io::stdout(), "\u{1b}[{}A", clear_rows - 1)?;
        }

        if clear_rows > 0 {
            write!(io::stdout(), "\r")?;
        }

        for line in &output_lines {
            writeln!(io::stdout(), "{line}")?;
        }

        io::stdout().flush()?;
        self.rendered_lines = output_lines.len();
        self.rendered_width = render_width;
        self.rendered_line_widths = output_lines
            .iter()
            .map(|line| visible_char_count(line))
            .collect();
        Ok(())
    }

    fn rendered_output_lines(&self, width: usize, visible_capacity: usize) -> Vec<String> {
        let mut output_lines = Vec::with_capacity(
            self.prefix_lines.len() + visible_capacity + usize::from(self.loader_line.is_some()),
        );
        let tail_notice_index = self.prefix_lines.len().saturating_sub(1);
        output_lines.extend(
            self.prefix_lines[..tail_notice_index]
                .iter()
                .map(|line| status_line_text_for_width(line, width)),
        );
        if let Some(loader_line) = self.loader_line.as_ref() {
            output_lines.push(status_line_text_for_width(loader_line, width));
        }
        output_lines.extend(
            self.prefix_lines[tail_notice_index..]
                .iter()
                .map(|line| status_line_text_for_width(line, width)),
        );
        output_lines.extend(
            self.lines
                .iter()
                .map(|line| tail_line_text_for_width(line, width)),
        );
        output_lines.extend((self.lines.len()..visible_capacity).map(|_| String::new()));
        output_lines
    }

    fn clear(&mut self) -> io::Result<()> {
        let rows = physical_rows_for_width(&self.rendered_line_widths, terminal_width().max(8));
        if rows == 0 {
            return Ok(());
        }

        write!(io::stdout(), "\u{1b}[{}A", rows)?;
        for index in 0..=rows {
            write!(io::stdout(), "\r\u{1b}[2K")?;
            if index < rows {
                write!(io::stdout(), "\n")?;
            }
        }
        write!(io::stdout(), "\u{1b}[{}A\r", rows)?;
        io::stdout().flush()?;
        self.rendered_lines = 0;
        self.rendered_width = terminal_width().max(8);
        self.rendered_line_widths.clear();
        Ok(())
    }
}

fn physical_rows_for_width(line_widths: &[usize], terminal_width: usize) -> usize {
    let terminal_width = terminal_width.max(1);
    line_widths
        .iter()
        .map(|width| (*width).max(1).div_ceil(terminal_width))
        .sum()
}

#[derive(Clone, Copy)]
struct Rgb {
    r: u8,
    g: u8,
    b: u8,
}

impl Rgb {
    const fn new(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b }
    }
}

fn interpolate_color(cool: Rgb, warm: Rgb, load: f32) -> Rgb {
    let load = load.clamp(0.0, 1.0);
    let interpolate =
        |from: u8, to: u8| (from as f32 + (to as f32 - from as f32) * load).round() as u8;

    Rgb::new(
        interpolate(cool.r, warm.r),
        interpolate(cool.g, warm.g),
        interpolate(cool.b, warm.b),
    )
}

fn rgb_code(color: Rgb) -> String {
    format!("38;2;{};{};{}", color.r, color.g, color.b)
}

#[cfg(test)]
fn spinner_kitt_frame(frame_index: usize) -> String {
    spinner_kitt_frame_with_load(frame_index, 0.0)
}

fn spinner_kitt_frame_with_load(frame_index: usize, load: f32) -> String {
    let width = 8usize;
    let scan_frames = 30usize;
    let edge_hold_frames = 4usize;
    let half_cycle_frames = scan_frames + edge_hold_frames;
    let cycle_length = half_cycle_frames * 2;
    let cycle_index = frame_index % cycle_length;
    let phase_index = cycle_index % half_cycle_frames;
    let moving_right = cycle_index < half_cycle_frames;
    let pulse_codes = [
        Some("38;2;72;84;112"),
        Some("38;2;72;84;112"),
        Some("38;2;71;83;111"),
        Some("38;2;70;82;109"),
        Some("38;2;69;80;107"),
        Some("38;2;67;78;104"),
        Some("38;2;65;76;101"),
        Some("38;2;63;73;98"),
        Some("38;2;60;70;94"),
        Some("38;2;57;67;90"),
        Some("38;2;54;64;85"),
        Some("38;2;51;60;80"),
        Some("38;2;48;56;76"),
        Some("38;2;45;53;71"),
        Some("38;2;42;49;66"),
        Some("38;2;38;45;60"),
        Some("38;2;35;41;55"),
        Some("38;2;32;38;50"),
        Some("38;2;29;34;46"),
        Some("38;2;26;30;41"),
        Some("38;2;23;27;36"),
        Some("38;2;20;24;32"),
        Some("38;2;17;21;28"),
        Some("38;2;15;18;25"),
        Some("38;2;13;16;22"),
        Some("38;2;11;14;19"),
        Some("38;2;10;12;17"),
        Some("38;2;9;11;15"),
        Some("38;2;8;10;14"),
        Some("38;2;8;10;14"),
        Some("38;2;8;10;14"),
        Some("38;2;8;10;14"),
        Some("38;2;9;11;15"),
        Some("38;2;10;12;17"),
        Some("38;2;11;14;19"),
        Some("38;2;13;16;22"),
        Some("38;2;15;18;25"),
        Some("38;2;17;21;28"),
        Some("38;2;20;24;32"),
        Some("38;2;23;27;36"),
        Some("38;2;26;30;41"),
        Some("38;2;29;34;46"),
        Some("38;2;32;38;50"),
        Some("38;2;35;41;55"),
        Some("38;2;38;45;60"),
        Some("38;2;42;49;66"),
        Some("38;2;45;53;71"),
        Some("38;2;48;56;76"),
        Some("38;2;51;60;80"),
        Some("38;2;54;64;85"),
        Some("38;2;57;67;90"),
        Some("38;2;60;70;94"),
        Some("38;2;63;73;98"),
        Some("38;2;65;76;101"),
        Some("38;2;67;78;104"),
        Some("38;2;69;80;107"),
        Some("38;2;70;82;109"),
        Some("38;2;71;83;111"),
        Some("38;2;72;84;112"),
        Some("38;2;72;84;112"),
    ];
    let trail_colors = [
        interpolate_color(Rgb::new(214, 236, 255), Rgb::new(255, 229, 168), load),
        interpolate_color(Rgb::new(125, 211, 252), Rgb::new(255, 183, 107), load),
        interpolate_color(Rgb::new(96, 165, 250), Rgb::new(248, 135, 80), load),
        interpolate_color(Rgb::new(59, 130, 246), Rgb::new(214, 93, 63), load),
    ];
    let fade_distance = trail_colors.len();
    let travel_distance = width + fade_distance;
    let active_position = phase_index.min(scan_frames - 1) * travel_distance / scan_frames;
    let mut output = String::new();

    for index in 0..width {
        let color_index = if moving_right {
            active_position as isize - index as isize
        } else {
            index as isize - (width as isize - 1 - active_position as isize)
        };

        if color_index >= 0 && (color_index as usize) < trail_colors.len() {
            output.push_str(&style(&rgb_code(trail_colors[color_index as usize]), "■"));
        } else {
            match pulse_codes[frame_index % pulse_codes.len()] {
                Some(code) if use_color() => {
                    if load <= 0.01 {
                        output.push_str(&style(code, "·"));
                    } else {
                        let cool = pulse_color(frame_index % pulse_codes.len());
                        let warm = Rgb::new(72, 54, 48);
                        output.push_str(&style(
                            &rgb_code(interpolate_color(cool, warm, load * 0.55)),
                            "·",
                        ));
                    }
                }
                Some(_) => output.push('.'),
                None => output.push(' '),
            }
        }
    }

    output
}

fn pulse_color(index: usize) -> Rgb {
    let cycle_index = index.min(59);
    let distance_from_edge = if cycle_index <= 29 {
        cycle_index
    } else {
        59 - cycle_index
    };
    let brightness = 1.0 - distance_from_edge as f32 / 29.0;
    let r = (8.0 + (72.0 - 8.0) * brightness).round() as u8;
    let g = (10.0 + (84.0 - 10.0) * brightness).round() as u8;
    let b = (14.0 + (112.0 - 14.0) * brightness).round() as u8;

    Rgb::new(r, g, b)
}

struct SpinnerRenderer {
    tty: File,
    tty_guard: TtyModeGuard,
    frame: usize,
    frame_interval: Duration,
    next_frame_at: Instant,
    second_escape_deadline: Option<Instant>,
    resource_sampler: ResourceSampler,
    resource_history: ResourceHistory,
    resource_history_revision: u64,
    cpu_visual_load: f32,
    ram_visual_load: f32,
    resource_visual_load: f32,
    rendered_block_line_widths: Vec<usize>,
}

enum InputEvent {
    None,
    Interrupt,
    StartTail,
    IncreaseLines,
    DecreaseLines,
}

impl SpinnerRenderer {
    fn new() -> io::Result<Self> {
        let tty = File::options().read(true).write(true).open("/dev/tty")?;
        let tty_guard = TtyModeGuard::new(&tty)?;

        if use_color() {
            write!(io::stdout(), "\u{1b}[?25l")?;
            io::stdout().flush()?;
        }

        Ok(Self {
            tty,
            tty_guard,
            frame: 0,
            frame_interval: Duration::from_millis(33),
            next_frame_at: Instant::now(),
            second_escape_deadline: None,
            resource_sampler: ResourceSampler::new(),
            resource_history: ResourceHistory::new(),
            resource_history_revision: 0,
            cpu_visual_load: 0.0,
            ram_visual_load: 0.0,
            resource_visual_load: 0.0,
            rendered_block_line_widths: Vec::new(),
        })
    }

    fn poll_input(&mut self) -> io::Result<InputEvent> {
        let mut buffer = [0_u8; 1];
        match self.tty.read(&mut buffer) {
            Ok(1) if buffer[0] == 0x1b => {
                let now = Instant::now();
                if self
                    .second_escape_deadline
                    .is_some_and(|deadline| deadline > now)
                {
                    self.second_escape_deadline = None;
                    return Ok(InputEvent::Interrupt);
                }
                self.second_escape_deadline = Some(now + Duration::from_secs(3));
                Ok(InputEvent::None)
            }
            Ok(1) if buffer[0] == b't' || buffer[0] == b'T' => Ok(InputEvent::StartTail),
            Ok(1) if buffer[0] == b'+' => Ok(InputEvent::IncreaseLines),
            Ok(1) if buffer[0] == b'-' => Ok(InputEvent::DecreaseLines),
            Ok(_) => Ok(InputEvent::None),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(InputEvent::None),
            Err(error) => Err(error),
        }
    }

    fn current_spinner_hint(&mut self) -> String {
        if self
            .second_escape_deadline
            .is_some_and(|deadline| deadline > Instant::now())
        {
            spinner_hint("again to interrupt")
        } else {
            self.second_escape_deadline = None;
            spinner_hint("interrupt")
        }
    }

    fn current_dashboard_hint(&mut self) -> String {
        dashboard_hint(&self.current_spinner_hint())
    }

    fn render_frame_with_hint(&mut self, pid: u32, hint: &str) -> io::Result<()> {
        let line = self.frame_line_with_hint(pid, hint)?;
        write!(io::stdout(), "\r\u{1b}[2K{}", line)?;
        io::stdout().flush()?;
        Ok(())
    }

    fn frame_line_with_hint(&mut self, pid: u32, hint: &str) -> io::Result<String> {
        let now = Instant::now();
        if self.next_frame_at > now {
            thread::sleep(self.next_frame_at - now);
        }

        let resource_sample = self.resource_sampler.sample(pid).unwrap_or(None);
        self.sync_resource_history(resource_sample.as_ref());
        self.update_resource_visuals(resource_sample.as_ref());
        let resource_text = resource_sample
            .as_ref()
            .map(|sample| {
                format_resource_metrics(
                    sample,
                    &self.resource_history,
                    self.cpu_visual_load,
                    self.ram_visual_load,
                )
            })
            .unwrap_or_default();
        let suffix = if resource_text.is_empty() {
            hint.to_owned()
        } else {
            format!("{} {} {}", resource_text, dim_text("|"), hint)
        };

        let line = format!(
            "{}  {}",
            spinner_kitt_frame_with_load(self.frame, self.resource_visual_load),
            suffix
        );
        self.frame += 1;
        self.next_frame_at = Instant::now() + self.frame_interval();
        Ok(line)
    }

    fn render_dashboard(
        &mut self,
        pid: u32,
        global_elapsed: Duration,
        completed_summaries: &[CommandSummary],
        current_detail_lines: &[String],
        metadata: &BackendMetadata,
        hint: &str,
    ) -> io::Result<()> {
        let now = Instant::now();
        if self.next_frame_at > now {
            thread::sleep(self.next_frame_at - now);
        }

        let resource_sample = self.resource_sampler.sample(pid).unwrap_or(None);
        self.sync_resource_history(resource_sample.as_ref());
        self.update_resource_visuals(resource_sample.as_ref());
        let resource_text = resource_sample
            .as_ref()
            .map(|sample| {
                format_resource_metrics(
                    sample,
                    &self.resource_history,
                    self.cpu_visual_load,
                    self.ram_visual_load,
                )
            })
            .unwrap_or_default();
        let spinner_suffix = if resource_text.is_empty() {
            hint.to_owned()
        } else {
            format!("{} {} {}", resource_text, dim_text("|"), hint)
        };

        let lines = dashboard_output_lines(
            global_elapsed,
            completed_summaries,
            current_detail_lines,
            metadata,
            self.frame,
            self.resource_visual_load,
            &spinner_suffix,
        );

        let render_width = terminal_width().max(8);
        let lines = lines
            .iter()
            .map(|line| status_line_text_for_width(line, render_width))
            .collect::<Vec<_>>();

        self.clear_dynamic_block()?;
        for (index, line) in lines.iter().enumerate() {
            if index + 1 == lines.len() {
                write!(io::stdout(), "\r\u{1b}[2K{}", line)?;
            } else {
                writeln!(io::stdout(), "\r\u{1b}[2K{}", line)?;
            }
        }

        io::stdout().flush()?;
        self.rendered_block_line_widths =
            lines.iter().map(|line| visible_char_count(line)).collect();
        self.frame += 1;
        self.next_frame_at = Instant::now() + self.frame_interval();
        Ok(())
    }

    fn update_resource_visuals(&mut self, sample: Option<&ResourceSample>) {
        let target_cpu_load = sample.map(cpu_metric_load).unwrap_or(0.0);
        let target_ram_load = sample.map(ram_metric_load).unwrap_or(0.0);
        self.cpu_visual_load += (target_cpu_load - self.cpu_visual_load) * 0.06;
        self.ram_visual_load += (target_ram_load - self.ram_visual_load) * 0.06;
        let target_load = sample.map(resource_visual_load).unwrap_or(0.0);
        self.resource_visual_load += (target_load - self.resource_visual_load) * 0.06;
    }

    fn sync_resource_history(&mut self, sample: Option<&ResourceSample>) {
        let revision = self.resource_sampler.revision();
        if revision == self.resource_history_revision {
            return;
        }
        self.resource_history_revision = revision;
        if let Some(sample) = sample {
            self.resource_history.push(*sample);
        }
    }

    fn frame_interval(&self) -> Duration {
        let load = self.resource_visual_load.clamp(0.0, 1.0);
        let millis = self.frame_interval.as_millis() as f32;
        Duration::from_millis((millis - 6.0 * load).round() as u64)
    }

    fn clear_line(&mut self) {
        // Erase either the live dashboard block or the single-line spinner.
        // The single-line path matters for commands that do not emit metadata
        // until completion; otherwise the final summary can be written after
        // the spinner text on the same terminal row.
        if self.rendered_block_line_widths.is_empty() {
            let _ = write!(io::stdout(), "\r\u{1b}[2K");
        } else {
            let _ = self.clear_dynamic_block();
        }
        let _ = io::stdout().flush();
    }

    fn show_cursor(&self) {
        if use_color() {
            let _ = write!(io::stdout(), "\u{1b}[?25h");
            let _ = io::stdout().flush();
        }
    }

    fn clear_frame_line(&mut self) {
        if !self.rendered_block_line_widths.is_empty() {
            let _ = self.clear_dynamic_block();
            let _ = io::stdout().flush();
            return;
        }
        let _ = write!(io::stdout(), "\r\u{1b}[2K");
        let _ = io::stdout().flush();
    }

    fn clear_dynamic_block(&mut self) -> io::Result<()> {
        let rendered_rows =
            physical_rows_for_width(&self.rendered_block_line_widths, terminal_width().max(8));
        if rendered_rows == 0 {
            return Ok(());
        }

        write!(io::stdout(), "\r\u{1b}[2K")?;
        for _ in 1..rendered_rows {
            write!(io::stdout(), "\u{1b}[1A\r\u{1b}[2K")?;
        }
        self.rendered_block_line_widths.clear();
        Ok(())
    }
}

fn dashboard_output_lines(
    global_elapsed: Duration,
    completed_summaries: &[CommandSummary],
    current_detail_lines: &[String],
    metadata: &BackendMetadata,
    frame: usize,
    resource_visual_load: f32,
    spinner_suffix: &str,
) -> Vec<String> {
    let total_lines = 1
        + completed_summaries
            .iter()
            .map(|s| 1 + s.detail_lines.len())
            .sum::<usize>()
        + 2
        + current_detail_lines.len();
    let mut lines = Vec::with_capacity(total_lines);
    lines.push(format!(
        "{}",
        dim_text(&format!(
            "Working for {} >",
            format_duration(global_elapsed)
        ))
    ));
    for summary in completed_summaries {
        lines.push(completed_summary_line(summary));
        for dl in &summary.detail_lines {
            lines.push(detail_line(dl));
        }
    }
    lines.push(running_command_line(metadata));
    for dl in current_detail_lines {
        lines.push(detail_line(dl));
    }
    lines.push(format!(
        "{}  {}",
        spinner_kitt_frame_with_load(frame, resource_visual_load),
        spinner_suffix
    ));
    lines
}

#[derive(Clone, Copy)]
struct ResourceSample {
    cpu_percent: f32,
    rss_kb: u64,
}

struct ResourceSampler {
    last_sample_at: Option<Instant>,
    last_sample: Option<ResourceSample>,
    sample_revision: u64,
}

impl ResourceSampler {
    const SAMPLE_INTERVAL: Duration = Duration::from_secs(2);

    fn new() -> Self {
        Self {
            last_sample_at: None,
            last_sample: None,
            sample_revision: 0,
        }
    }

    fn sample(&mut self, pid: u32) -> io::Result<Option<ResourceSample>> {
        if pid == 0 {
            return Ok(None);
        }

        let now = Instant::now();
        if let (Some(last_sample_at), Some(last_sample)) =
            (self.last_sample_at, self.last_sample.as_ref())
        {
            if now.duration_since(last_sample_at) < Self::SAMPLE_INTERVAL {
                return Ok(Some(*last_sample));
            }
        }

        let sample = read_resource_sample(pid)?;
        self.last_sample_at = Some(now);
        self.last_sample = Some(sample);
        self.sample_revision += 1;
        Ok(self.last_sample)
    }

    fn revision(&self) -> u64 {
        self.sample_revision
    }
}

struct ResourceHistory {
    cpu_percent: Vec<f32>,
    rss_kb: Vec<u64>,
}

impl ResourceHistory {
    const WIDTH: usize = 6;

    fn new() -> Self {
        Self {
            cpu_percent: Vec::with_capacity(Self::WIDTH),
            rss_kb: Vec::with_capacity(Self::WIDTH),
        }
    }

    fn push(&mut self, sample: ResourceSample) {
        push_ring_value(&mut self.cpu_percent, sample.cpu_percent, Self::WIDTH);
        push_ring_value(&mut self.rss_kb, sample.rss_kb, Self::WIDTH);
    }
}

fn read_resource_sample(root_pid: u32) -> io::Result<ResourceSample> {
    let output = process::Command::new("ps")
        .args(["-axo", "pid=,ppid=,%cpu=,rss="])
        .output()?;
    if !output.status.success() {
        return Ok(ResourceSample {
            cpu_percent: 0.0,
            rss_kb: 0,
        });
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut parent_by_pid = HashMap::new();
    let mut metrics_by_pid = HashMap::new();

    for line in stdout.lines() {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        if fields.len() != 4 {
            continue;
        }

        let Ok(pid) = fields[0].parse::<u32>() else {
            continue;
        };
        let Ok(ppid) = fields[1].parse::<u32>() else {
            continue;
        };
        let Ok(cpu_percent) = fields[2].replace(',', ".").parse::<f32>() else {
            continue;
        };
        let Ok(rss_kb) = fields[3].parse::<u64>() else {
            continue;
        };

        parent_by_pid.insert(pid, ppid);
        metrics_by_pid.insert(pid, (cpu_percent, rss_kb));
    }

    let mut descendants = HashSet::from([root_pid]);
    let mut changed = true;
    while changed {
        changed = false;
        for (&pid, &ppid) in &parent_by_pid {
            if descendants.contains(&ppid) && descendants.insert(pid) {
                changed = true;
            }
        }
    }

    let mut cpu_percent = 0.0;
    let mut rss_kb = 0;
    for pid in descendants {
        if let Some((pid_cpu_percent, pid_rss_kb)) = metrics_by_pid.get(&pid) {
            cpu_percent += *pid_cpu_percent;
            rss_kb += *pid_rss_kb;
        }
    }

    Ok(ResourceSample {
        cpu_percent,
        rss_kb,
    })
}

fn format_resource_metrics(
    sample: &ResourceSample,
    history: &ResourceHistory,
    cpu_load: f32,
    ram_load: f32,
) -> String {
    let cpu_text = format_resource_sample_cpu(sample, history);
    let ram_text = format_resource_sample_ram(sample, history);
    format!(
        "{} {} {}",
        adaptive_metric_text(&cpu_text, cpu_load),
        dim_text("|"),
        adaptive_metric_text(&ram_text, ram_load)
    )
}

#[cfg(test)]
fn format_resource_sample(sample: &ResourceSample, history: &ResourceHistory) -> String {
    format!(
        "{} | {}",
        format_resource_sample_cpu(sample, history),
        format_resource_sample_ram(sample, history)
    )
}

fn format_resource_sample_cpu(sample: &ResourceSample, history: &ResourceHistory) -> String {
    let cpu_sparkline = sparkline_f32(&history.cpu_percent, ResourceHistory::WIDTH, 250.0);
    format!(
        "cpu {} {:>4}%",
        cpu_sparkline,
        sample.cpu_percent.round() as u32
    )
}

fn format_resource_sample_ram(sample: &ResourceSample, history: &ResourceHistory) -> String {
    let ram = format_kib(sample.rss_kb);
    let ram_sparkline = sparkline_u64(&history.rss_kb, ResourceHistory::WIDTH);
    format!("ram {}  {}", ram_sparkline, ram)
}

fn push_ring_value<T>(values: &mut Vec<T>, value: T, max_len: usize) {
    if values.len() == max_len {
        values.remove(0);
    }
    values.push(value);
}

fn sparkline_f32(values: &[f32], width: usize, max_value: f32) -> String {
    if values.is_empty() {
        return " ".repeat(width);
    }
    let normalized = values
        .iter()
        .map(|value| (value / max_value).clamp(0.0, 1.0))
        .collect::<Vec<_>>();
    sparkline_from_normalized(&normalized, width)
}

fn sparkline_u64(values: &[u64], width: usize) -> String {
    if values.is_empty() {
        return " ".repeat(width);
    }
    let peak = values.iter().copied().max().unwrap_or(0);
    if peak == 0 {
        return " ".repeat(width);
    }
    let normalized = values
        .iter()
        .map(|value| (*value as f32 / peak as f32).clamp(0.0, 1.0))
        .collect::<Vec<_>>();
    sparkline_from_normalized(&normalized, width)
}

fn sparkline_from_normalized(values: &[f32], width: usize) -> String {
    const SPARKS: [char; 8] = [' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇'];

    let mut sparkline = String::with_capacity(width);
    for _ in 0..width.saturating_sub(values.len()) {
        sparkline.push(' ');
    }
    for value in values {
        let index = ((*value * (SPARKS.len() - 1) as f32).round() as usize).min(SPARKS.len() - 1);
        sparkline.push(SPARKS[index]);
    }
    sparkline
}

fn resource_visual_load(sample: &ResourceSample) -> f32 {
    cpu_metric_load(sample).max(ram_metric_load(sample))
}

fn format_kib(kib: u64) -> String {
    const MIB: u64 = 1024;
    const GIB: u64 = 1024 * 1024;

    if kib >= GIB {
        return format!("{:.2} GiB", kib as f64 / GIB as f64);
    }

    if kib >= MIB {
        return format!("{} MiB", (kib as f64 / MIB as f64).round() as u64);
    }

    format!("{} KiB", kib)
}

impl Drop for SpinnerRenderer {
    fn drop(&mut self) {
        self.clear_line();
        let _ = &self.tty_guard;
    }
}

struct TtyModeGuard {
    fd: i32,
    original: libc::termios,
}

impl TtyModeGuard {
    fn new(file: &File) -> io::Result<Self> {
        let fd = file.as_raw_fd();
        let original = get_termios(fd)?;
        let mut raw = original;
        raw.c_lflag &= !(libc::ECHO | libc::ICANON);
        raw.c_cc[libc::VMIN] = 0;
        raw.c_cc[libc::VTIME] = 0;
        set_termios(fd, &raw)?;
        Ok(Self { fd, original })
    }
}

impl Drop for TtyModeGuard {
    fn drop(&mut self) {
        let _ = set_termios(self.fd, &self.original);
    }
}

fn get_termios(fd: i32) -> io::Result<libc::termios> {
    let mut termios = MaybeUninit::<libc::termios>::uninit();
    let rc = unsafe { libc::tcgetattr(fd, termios.as_mut_ptr()) };
    if rc == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { termios.assume_init() })
}

fn set_termios(fd: i32, termios: &libc::termios) -> io::Result<()> {
    let rc = unsafe { libc::tcsetattr(fd, libc::TCSANOW, termios) };
    if rc == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn resolve_repo_root(repo_override: Option<OsString>) -> Result<PathBuf, String> {
    let resolved = canonical_repo_candidate(repo_override.as_ref())?;

    if let Some(git_root) = find_git_root(&resolved) {
        return Ok(git_root);
    }

    Ok(resolved)
}

fn canonical_repo_candidate(repo_override: Option<&OsString>) -> Result<PathBuf, String> {
    let candidate = match repo_override {
        Some(path) => PathBuf::from(path),
        None => env::current_dir()
            .map_err(|error| format!("failed to resolve current directory: {error}"))?,
    };

    if !candidate.is_dir() {
        return Err(format!(
            "Repository path does not exist: {}",
            candidate.display()
        ));
    }

    candidate.canonicalize().map_err(|error| {
        format!(
            "failed to resolve repository path {}: {error}",
            candidate.display()
        )
    })
}

fn find_git_root(resolved: &Path) -> Option<PathBuf> {
    for current in resolved.ancestors() {
        let git_dir = current.join(".git");
        if git_dir.is_dir() || git_dir.is_file() {
            return Some(current.to_path_buf());
        }
    }

    None
}

fn require_repo_path_is_git_root_for_strict_commands(
    repo_override: Option<&OsString>,
    command_segments: &[(OsString, Vec<OsString>)],
) -> Result<(), String> {
    let Some(command) = command_segments
        .iter()
        .map(|(command, _)| command.to_string_lossy())
        .find(|command| matches!(command.as_ref(), "doctor" | "init"))
    else {
        return Ok(());
    };

    let resolved = canonical_repo_candidate(repo_override)?;
    if let Some(git_root) = find_git_root(&resolved) {
        if resolved != git_root {
            return Err(format!(
                "makevn {command} must be run from the Git repository root: {} (received: {})",
                git_root.display(),
                resolved.display()
            ));
        }
    }

    Ok(())
}

fn install_root(current_exe: &Path) -> Result<PathBuf, String> {
    if let Some(root) = env::var_os("MAKEVN_INSTALL_ROOT") {
        if !root.is_empty() {
            return Ok(PathBuf::from(root));
        }
    }

    if let Ok(root) = install_root_with_override(current_exe, None) {
        if root.join("libexec/makevn/backend.sh").is_file() {
            return Ok(root);
        }
    }

    if let Some(root) = install_root_from_path() {
        return Ok(root);
    }

    install_root_with_override(current_exe, None)
}

fn install_root_from_path() -> Option<PathBuf> {
    let path_var = env::var_os("PATH")?;
    env::split_paths(&path_var)
        .map(|dir| dir.join("makevn"))
        .filter(|candidate| candidate.is_file())
        .find_map(|candidate| {
            install_root_with_override(&candidate, None)
                .ok()
                .filter(|root| root.join("libexec/makevn/backend.sh").is_file())
        })
}

fn install_root_with_override(
    current_exe: &Path,
    install_root_override: Option<OsString>,
) -> Result<PathBuf, String> {
    if let Some(root) = install_root_override {
        if !root.is_empty() {
            return Ok(PathBuf::from(root));
        }
    }

    let resolved_exe = fs::canonicalize(current_exe).unwrap_or_else(|_| current_exe.to_path_buf());
    let bin_dir = resolved_exe.parent().ok_or_else(|| {
        format!(
            "failed to determine binary directory from {}",
            resolved_exe.display()
        )
    })?;

    bin_dir.parent().map(Path::to_path_buf).ok_or_else(|| {
        format!(
            "failed to determine install root from {}",
            resolved_exe.display()
        )
    })
}

fn exit_with_error(message: String) -> ! {
    eprintln!("Error: {message}");
    process::exit(1);
}

fn print_command_help(command: &str) {
    let Some((usage, description, options)) = command_help(command) else {
        eprintln!("Error: Unknown command: {command}");
        process::exit(1);
    };

    println!("makevn {command}");
    println!();
    println!("{description}");
    println!();
    println!("Usage:");
    println!("  {usage}");
    if !options.is_empty() {
        println!();
        println!("Options:");
        for option in options {
            println!("  {option}");
        }
    }
}

fn command_help(command: &str) -> Option<(&'static str, &'static str, &'static [&'static str])> {
    match command {
        "help" => Some(("makevn help", "Print the full makevn help.", &[])),
        "doctor" => Some(("makevn [--repo PATH] doctor", "Inspect repository setup and makevn configuration.", &[])),
        "init" => Some(("makevn [--repo PATH] init [--dry-run] [--force]", "Initialize .makevn configuration for the repository.", &["--dry-run  Show what would change without writing files", "--force    Refresh existing generated files"])),
        "make" => Some(("makevn [--repo PATH] make install|uninstall [--dry-run]", "Install or remove optional vn-* Make targets.", &["--dry-run  Show what would change without writing files"])),
        "uninstall" => Some(("makevn [--repo PATH] uninstall [--dry-run]", "Remove makevn local repository state.", &["--dry-run  Show what would be removed"])),
        "refresh" => Some(("makevn [--repo PATH] refresh [--dry-run]", "Reinitialize makevn state from scratch. Removes stale state and runs init --force.", &["--dry-run  Show what would change without writing files"])),
        "profile" => Some(("makevn [--repo PATH] profile refresh", "Refresh detected repository profile information.", &[])),
        "exec" => Some(("makevn [--repo PATH] exec [--context code|karate] -- COMMAND [ARGS...]", "Run an arbitrary command with makevn's resolved environment.", &["--context  Java context to use: code or karate"])),
        "compile" => maven_command_help("compile", "Compile project sources.", false),
        "test-compile" => maven_command_help("test-compile", "Compile project tests.", false),
        "compile-tests" => maven_command_help("compile-tests", "Compile project tests.", false),
        "validate" => maven_command_help("validate", "Validate the Maven project model.", false),
        "package" => maven_command_help("package", "Package the project without running tests.", false),
        "build" => maven_command_help("build", "Run the full Maven build.", false),
        "clean" => maven_command_help("clean", "Clean Maven build output.", false),
        "test" => Some(("makevn [--repo PATH] [--compact] test [--tail] [--name TEST]... [--fast] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]", "Run tests with optional filtering.", &["--tail                              Start in interactive log tail mode", "--compact                           Use compact non-interactive output", "--name                              Test class name or comma-separated names", "--fast                              Skip compilation when sources have not changed", "--clean-generated-contract-targets  Clean stale generated sources before running"])),
        "verify-ut" => maven_command_help("verify-ut", "Run unit-test-only verification.", true),
        "verify-ut-coverage" => maven_command_help("verify-ut-coverage", "Run unit-test-only verification with coverage.", true),
        "verify-it" => maven_command_help("verify-it", "Run integration-test-only verification.", true),
        "verify-it-coverage" => maven_command_help("verify-it-coverage", "Run integration-test-only verification with coverage.", true),
        "verify" => maven_command_help("verify", "Run full combined verification.", true),
        "verify-changes-preview" => Some(("makevn [--repo PATH] verify-changes-preview", "Preview changed production modules or modified tests without running Maven.", &[])),
        "verify-changes" => maven_command_help("verify-changes", "Verify changed production modules or modified tests.", true),
        "coverage" => Some(("makevn [--repo PATH] coverage [--threshold PCT]", "Check the latest aggregate coverage report.", &["--threshold  Required coverage percentage"])),
        "coverage-changes" => Some(("makevn [--repo PATH] coverage-changes [--threshold PCT] [--overall-threshold PCT] [--verbose]", "Check incremental and per-module coverage.", &["--threshold          Per-module coverage percentage", "--overall-threshold  Overall coverage percentage", "--verbose            Print detailed coverage output"])),
        "pr-verify" => maven_command_help("pr-verify", "Run a local PR-style verification flow.", false),
        "format" => Some(("makevn [--repo PATH] [--compact] format [--tail] [--apply] [-- EXTRA_MAVEN_ARGS...]", "Check or apply code formatting.", &["--tail     Start in interactive log tail mode", "--compact  Use compact non-interactive output", "--apply    Apply formatting changes"])),
        "checkstyle" => Some(("makevn [--repo PATH] [--compact] checkstyle [--tail] [--module MODULE] [--verbose] [-- EXTRA_MAVEN_ARGS...]", "Run Checkstyle code style checks.", &["--tail     Start in interactive log tail mode", "--compact  Use compact non-interactive output", "--module   Maven module to check", "--verbose  Print detailed output"])),
        "docker-up" => tail_command_help("docker-up", "Start boot Docker services."),
        "docker-down" => tail_command_help("docker-down", "Stop boot Docker services."),
        "docker-ps" => tail_command_help("docker-ps", "List boot Docker containers."),
        "docker-stats" => tail_command_help("docker-stats", "Show Docker CPU and memory stats."),
        "docker-ps-required" => Some(("makevn [--repo PATH] docker-ps-required [--tail] [--compose boot|karate] [--wait-seconds N]", "Validate required Docker services are running and healthy.", &["--tail          Start in interactive log tail mode", "--compose       Compose profile: boot or karate", "--wait-seconds  Seconds to wait for services"])),
        "karate-docker-up" => tail_command_help("karate-docker-up", "Start Karate E2E Docker services."),
        "karate-docker-down" => tail_command_help("karate-docker-down", "Stop Karate E2E Docker services."),
        "karate-test" => Some(("makevn [--repo PATH] karate-test [--tail] [--tag TAG] [-- EXTRA_MAVEN_ARGS...]", "Run Karate tests.", &["--tail  Start in interactive log tail mode", "--tag   Karate tag filter"])),
        "karate-all" => Some(("makevn [--repo PATH] karate-all [--tail] [--tag TAG] [-- EXTRA_MAVEN_ARGS...]", "Run the Karate app and test lifecycle.", &["--tail  Start in interactive log tail mode", "--tag   Karate tag filter"])),
        "run-app" => Some(("makevn [--repo PATH] run-app [--tail]", "Run the detected application in the foreground.", &["--tail  Start in interactive application log tail mode"])),
        "run-app-bg" => Some(("makevn [--repo PATH] run-app-bg", "Run the detected application in the background.", &[])),
        "stop-app" => Some(("makevn [--repo PATH] stop-app", "Stop the background application started by makevn.", &[])),
        "run" => Some(("makevn [--repo PATH] run", "Run the repository-configured command.", &[])),
        "jdk" => Some(("makevn [--repo PATH] jdk current|list", "Show or list discovered JDK installations.", &[])),
        "mutation" => Some(("makevn [--repo PATH] [--compact] mutation [--tail] [--module MODULE] [--verbose]", "Run PIT mutation testing.", &["--tail     Start in interactive log tail mode", "--compact  Use compact non-interactive output", "--module   Maven module to test", "--verbose  Print detailed output"])),
        _ => None,
    }
}

fn maven_command_help(
    command: &'static str,
    description: &'static str,
    clean_contract: bool,
) -> Option<(&'static str, &'static str, &'static [&'static str])> {
    let usage = match command {
        "compile" => "makevn [--repo PATH] [--compact] compile [--tail] [-- EXTRA_MAVEN_ARGS...]",
        "test-compile" => {
            "makevn [--repo PATH] [--compact] test-compile [--tail] [-- EXTRA_MAVEN_ARGS...]"
        }
        "compile-tests" => {
            "makevn [--repo PATH] [--compact] compile-tests [--tail] [-- EXTRA_MAVEN_ARGS...]"
        }
        "validate" => "makevn [--repo PATH] [--compact] validate [--tail] [-- EXTRA_MAVEN_ARGS...]",
        "package" => "makevn [--repo PATH] [--compact] package [--tail] [-- EXTRA_MAVEN_ARGS...]",
        "build" => "makevn [--repo PATH] [--compact] build [--tail] [-- EXTRA_MAVEN_ARGS...]",
        "clean" => "makevn [--repo PATH] [--compact] clean [--tail] [-- EXTRA_MAVEN_ARGS...]",
        "verify-ut" => {
            "makevn [--repo PATH] [--compact] verify-ut [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"
        }
        "verify-ut-coverage" => {
            "makevn [--repo PATH] [--compact] verify-ut-coverage [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"
        }
        "verify-it" => {
            "makevn [--repo PATH] [--compact] verify-it [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"
        }
        "verify-it-coverage" => {
            "makevn [--repo PATH] [--compact] verify-it-coverage [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"
        }
        "verify" => "makevn [--repo PATH] [--compact] verify [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]",
        "verify-changes" => {
            "makevn [--repo PATH] [--compact] verify-changes [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"
        }
        "pr-verify" => {
            "makevn [--repo PATH] [--compact] pr-verify [--tail] [-- EXTRA_MAVEN_ARGS...]"
        }
        _ => return None,
    };
    let base_options = &[
        "--tail     Start in interactive log tail mode",
        "--compact  Use compact non-interactive output",
        "--          Forward remaining arguments to Maven",
    ];
    if clean_contract {
        let options: &[&str] = &[
            "--tail                              Start in interactive log tail mode",
            "--compact                           Use compact non-interactive output",
            "--clean-generated-contract-targets  Clean stale generated sources before running",
            "--                                  Forward remaining arguments to Maven",
        ];
        Some((usage, description, options))
    } else {
        Some((usage, description, base_options))
    }
}

fn tail_command_help(
    command: &'static str,
    description: &'static str,
) -> Option<(&'static str, &'static str, &'static [&'static str])> {
    let usage = match command {
        "docker-up" => "makevn [--repo PATH] docker-up [--tail]",
        "docker-down" => "makevn [--repo PATH] docker-down [--tail]",
        "docker-ps" => "makevn [--repo PATH] docker-ps [--tail]",
        "docker-stats" => "makevn [--repo PATH] docker-stats [--tail]",
        "karate-docker-up" => "makevn [--repo PATH] karate-docker-up [--tail]",
        "karate-docker-down" => "makevn [--repo PATH] karate-docker-down [--tail]",
        _ => return None,
    };
    Some((
        usage,
        description,
        &["--tail  Start in interactive log tail mode"],
    ))
}

fn print_help(with_header: bool) {
    if with_header {
        println!(":: makevn help");
    }

    println!("makevn {}", makevn_version());
    println!();
    println!("Terminal-first workflows for Java Maven repositories.");
    println!();
    println!("If a repository already uses Maven, local build and test flows should be runnable");
    println!("from the terminal without IDE-specific setup. Agents in OpenCode should prefer");
    println!("'makevn' commands over editor-specific instructions.");
    println!();
    println!("Usage:");
    println!("  makevn [--repo PATH] doctor");
    println!("  makevn [--repo PATH] init [--dry-run] [--force]");
    println!("  makevn [--repo PATH] refresh [--dry-run]");
    println!("  makevn [--repo PATH] make install [--dry-run]");
    println!("  makevn [--repo PATH] make uninstall [--dry-run]");
    println!("  makevn [--repo PATH] uninstall [--dry-run]");
    println!("  makevn [--repo PATH] profile refresh");
    println!("  makevn [--repo PATH] [--compact] compile [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] [--compact] test-compile [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] [--compact] compile-tests [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] [--compact] validate [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] [--compact] package [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] [--compact] build [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] [--compact] clean [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!(
        "  makevn [--repo PATH] [--compact] test [--tail] [--name TEST]... [--fast] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"
    );
    println!("  makevn [--repo PATH] [--compact] verify-ut [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]");
    println!(
        "  makevn [--repo PATH] [--compact] verify-ut-coverage [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"
    );
    println!("  makevn [--repo PATH] [--compact] verify-it [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]");
    println!(
        "  makevn [--repo PATH] [--compact] verify-it-coverage [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"
    );
    println!("  makevn [--repo PATH] [--compact] verify [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] verify-changes-preview");
    println!("  makevn [--repo PATH] [--compact] verify-changes [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] coverage [--threshold PCT]");
    println!("  makevn [--repo PATH] coverage-changes [--threshold PCT] [--overall-threshold PCT] [--verbose]");
    println!("  makevn [--repo PATH] [--compact] pr-verify [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!(
        "  makevn [--repo PATH] [--compact] format [--tail] [--apply] [-- EXTRA_MAVEN_ARGS...]"
    );
    println!(
        "  makevn [--repo PATH] [--compact] checkstyle [--tail] [--module MODULE] [--verbose] [-- EXTRA_MAVEN_ARGS...]"
    );
    println!("  makevn [--repo PATH] docker-up [--tail]");
    println!("  makevn [--repo PATH] docker-down [--tail]");
    println!("  makevn [--repo PATH] docker-ps [--tail]");
    println!("  makevn [--repo PATH] docker-stats [--tail]");
    println!("  makevn [--repo PATH] docker-ps-required [--tail] [--compose boot|karate] [--wait-seconds N]");
    println!("  makevn [--repo PATH] karate-docker-up [--tail]");
    println!("  makevn [--repo PATH] karate-docker-down [--tail]");
    println!("  makevn [--repo PATH] karate-test [--tail] [--tag TAG] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] karate-all [--tag TAG] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] run-app");
    println!("  makevn [--repo PATH] run-app-bg");
    println!("  makevn [--repo PATH] stop-app");
    println!("  makevn [--repo PATH] run");
    println!("  makevn [--repo PATH] exec [--context code|karate] -- COMMAND [ARGS...]");
    println!("  makevn [--repo PATH] jdk current");
    println!("  makevn [--repo PATH] jdk list");
    println!();
    println!("Examples:");
    println!("  makevn doctor");
    println!("  makevn init");
    println!("  makevn make install");
    println!("  makevn make uninstall");
    println!("  makevn profile refresh");
    println!("  makevn compile");
    println!("  makevn test-compile");
    println!("  makevn compile-tests");
    println!("  makevn validate");
    println!("  makevn package");
    println!("  makevn build");
    println!("  makevn clean");
    println!("  makevn test --name UserRepositoryTest");
    println!("  makevn test --name UserRepositoryTest,OrderRepositoryTest");
    println!("  makevn test --name UserRepositoryTest --name OrderRepositoryTest");
    println!("  makevn test --fast --name UserRepositoryTest");
    println!("  makevn verify-ut");
    println!("  makevn verify-ut-coverage");
    println!("  makevn verify-it");
    println!("  makevn verify-changes-preview");
    println!("  makevn verify-changes");
    println!("  makevn coverage");
    println!("  makevn coverage-changes");
    println!("  makevn pr-verify");
    println!("  makevn format --apply");
    println!("  makevn checkstyle --module domain --verbose");
    println!("  makevn docker-up");
    println!("  makevn docker-stats");
    println!("  makevn karate-test");
    println!("  makevn karate-test --tag @smoke");
    println!("  makevn run-app-bg");
    println!("  makevn stop-app");
    println!("  makevn exec -- mvn -q -v");
    println!("  make -f .makevn/makevn.mk vn-doctor");
    println!();
    println!("Notes:");
    println!("  - 'doctor' inspects the repository before and after initialization.");
    println!("  - 'init' always creates '.makevn/' without touching root makefiles.");
    println!("  - 'make install' adds optional 'vn-*' targets by updating one existing makefile or creating a minimal root Makefile.");
    println!("  - 'make uninstall' removes only the Make integration and keeps '.makevn/' intact.");
    println!("  - '--compact' forces compact agent-style summaries; non-interactive runs are compact by default.");
    println!("  - '--tail' starts managed-log commands in tail mode; without it, press 't' while a command is running to tail the current log.");
    println!("  - 'makevn-mcp' starts the MCP server over stdio (Model Context Protocol).");
}

fn print_mcp_help() {
    println!("makevn-mcp {}", makevn_version());
    println!();
    println!("Model Context Protocol server for makevn.");
    println!();
    println!("Usage:");
    println!("  makevn-mcp");
    println!("  makevn-mcp --help");
    println!("  makevn-mcp --version");
    println!();
    println!("Run without arguments from an MCP client. The server communicates over stdio.");
}

struct Lossy<'a>(&'a OsString);

impl fmt::Display for Lossy<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0.to_string_lossy())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        command_help, command_supports_frontend_loader, dashboard_hint, dim_text,
        format_resource_sample, insert_backend_option, install_root, install_root_with_override,
        parse_invocation, parse_mcp_invocation, read_backend_metadata, spinner_hint,
        spinner_kitt_frame, split_command_segments, strip_frontend_tail_flag, tail_status_lines,
        Action, BackendInvocation, BackendMetadata, CommandSummary, McpAction, ResourceHistory,
        ResourceSample,
    };
    use std::env;
    use std::ffi::OsString;
    use std::fs;
    use std::io::Write;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use std::path::Path;
    use std::process;
    use std::sync::Mutex;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    static ENV_LOCK: Mutex<()> = Mutex::new(());

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
        assert_eq!(lines[0], "Worked for 3s");
        assert_eq!(lines[1], "[ok]");
    }

    #[test]
    fn final_dashboard_omits_ok_on_failure() {
        let lines = super::final_dashboard_lines(Duration::from_secs(3), &[], false);
        assert_eq!(lines[0], "Worked for 3s");
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

        assert_eq!(lines[0], "Worked for 9m 34s");
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
    fn compact_disables_dashboard_loader_usage() {
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
    fn keeps_make_uninstall_as_make_subcommand() {
        let repo_root = current_repo_root();
        let action =
            parse_invocation(vec![OsString::from("make"), OsString::from("uninstall")]).unwrap();

        assert_eq!(
            action,
            Action::DispatchToBackend(vec![BackendInvocation {
                args: vec![
                    OsString::from("make"),
                    OsString::from("--repo"),
                    repo_root,
                    OsString::from("uninstall"),
                ],
                frontend_loader: false,
                tail: false,
                compact: false,
            }])
        );
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
        let error =
            strip_frontend_tail_flag(&OsString::from("doctor"), vec![OsString::from("--tail")])
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
            "make",
            "uninstall",
            "profile",
            "exec",
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
        assert_eq!(lines[2], ":: makevn checkstyle");
        assert_eq!(lines[3], " └ tailing log: .makevn/logs/checkstyle.log");
    }

    #[test]
    fn tail_window_places_loader_above_tailed_log() {
        let log_path = env::temp_dir().join("makevn-tail-loader-order.log");
        let mut tail_window = super::LogTailWindow::new(log_path);
        tail_window.set_prefix_lines(vec![
            String::from("Working for 1s >"),
            String::from(":: makevn compile"),
            String::from("-> tailing log: .makevn/logs/compile.log"),
        ]);
        tail_window.set_loader_line(Some(String::from("........  esc interrupt")));
        tail_window.lines.push(String::from("[INFO] compiling"));

        let lines = tail_window.rendered_output_lines(120, 1);

        assert_eq!(lines[0], "Working for 1s >");
        assert_eq!(lines[1], ":: makevn compile");
        assert_eq!(lines[2], "........  esc interrupt");
        assert_eq!(lines[3], "-> tailing log: .makevn/logs/compile.log");
        assert_eq!(
            super::visible_char_count(&lines[4]),
            "[INFO] compiling".len()
        );
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
            ":: makevn coverage-changes | .makevn/logs/coverage-changes.log"
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

        assert_eq!(lines[0], "Worked for 5s");
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
    fn running_command_line_uses_flat_prefix_for_logged_commands() {
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
            ":: makevn verify | .makevn/logs/verify.log"
        );
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
    fn rejects_git_exec_command() {
        let error = parse_invocation(vec![
            OsString::from("exec"),
            OsString::from("--"),
            OsString::from("git"),
            OsString::from("status"),
        ])
        .unwrap_err();
        assert_eq!(
            error,
            "makevn exec only supports Maven, Java, or repo-local executable commands; use native agent shell tools for git"
        );
    }

    #[test]
    fn accepts_repo_local_exec_command() {
        let action = parse_invocation(vec![
            OsString::from("exec"),
            OsString::from("--"),
            OsString::from("./script.sh"),
        ])
        .unwrap();
        assert!(matches!(action, Action::DispatchToBackend(_)));
    }
}
