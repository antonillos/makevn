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
use std::os::unix::process::ExitStatusExt;

#[cfg(unix)]
use signal_hook::consts::signal::{SIGINT, SIGTERM};

fn main() {
    let action = match parse_invocation(env::args_os().skip(1).collect()) {
        Ok(action) => action,
        Err(message) => exit_with_error(message),
    };

    if let Action::PrintVersion = action {
        println!(env!("CARGO_PKG_VERSION"));
        return;
    }

    if let Action::PrintHelp { with_header } = action {
        print_help(with_header);
        return;
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

#[derive(Debug, Eq, PartialEq)]
enum Action {
    PrintVersion,
    PrintHelp { with_header: bool },
    DispatchToBackend(Vec<BackendInvocation>),
}

#[derive(Debug, Eq, PartialEq)]
struct BackendInvocation {
    args: Vec<OsString>,
    frontend_loader: bool,
    tail: bool,
}

const COMMAND_SEQUENCE_BREAKERS: &[&str] = &["--", "--tail", "--name", "--mode", "--context"];

#[derive(Debug)]
struct BackendMetadataFile {
    path: PathBuf,
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

    if command == OsString::from("help") {
        let _ = resolve_repo_root(repo_override)?;
        return Ok(Action::PrintHelp { with_header: true });
    }

    let backend_invocations = build_backend_invocations(
        repo_override,
        command_segments,
        command_validation,
        global_tail,
    )?;
    Ok(Action::DispatchToBackend(backend_invocations))
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
    match command.to_string_lossy().as_ref() {
        "help" | "doctor" | "init" | "uninstall" | "exec" | "compile" | "compile-tests"
        | "validate" | "package" | "clean" | "build" | "test" | "verify-ut"
        | "verify-ut-coverage" | "verify-it" | "verify-it-coverage" | "verify"
        | "verify-changes" | "pr-verify" | "docker-up" | "docker-down" | "docker-ps"
        | "docker-ps-required" | "run" => {
            Ok(CommandValidation::Valid)
        }
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

fn build_backend_invocations(
    repo_override: Option<OsString>,
    command_segments: Vec<(OsString, Vec<OsString>)>,
    _command_validation: CommandValidation,
    global_tail_prefix: bool,
) -> Result<Vec<BackendInvocation>, String> {
    let repo_root = resolve_repo_root(repo_override)?;
    let (command_segments, global_options) = split_trailing_global_options(command_segments);
    let global_tail = global_tail_prefix || global_options.iter().any(|arg| arg == &OsString::from("--tail"));
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
        backend_args.extend(trailing_args);
        backend_invocations.push(BackendInvocation {
            args: backend_args,
            frontend_loader,
            tail,
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
            | "uninstall"
            | "profile"
            | "exec"
            | "compile"
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
            | "verify-changes"
            | "pr-verify"
            | "docker-up"
            | "docker-down"
            | "docker-ps"
            | "docker-ps-required"
            | "run"
            | "jdk"
    )
}

fn command_option_takes_value(arg: &OsString) -> bool {
    matches!(arg.to_string_lossy().as_ref(), "--name" | "--mode" | "--context")
}

fn is_global_option(arg: &OsString) -> bool {
    matches!(arg.to_string_lossy().as_ref(), "--tail")
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
            | "verify-changes"
            | "pr-verify"
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

    for mut backend_invocation in backend_invocations {
        let use_frontend_loader = backend_invocation.frontend_loader && frontend_loader_is_available();
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
        command.env("MAKEVN_BIN_PATH", current_exe);
        command.env("MAKEVN_INSTALL_ROOT", install_root);
        command.env("MAKEVN_FRONTEND", "rust");
        command.env("MAKEVN_FRONTEND_VERSION", env!("CARGO_PKG_VERSION"));
        command.env("MAKEVN_VERSION", env!("CARGO_PKG_VERSION"));

        let exit_code = if use_frontend_loader {
            command.env("MAKEVN_FRONTEND_OWNS_LOADER", "1");
            run_backend_with_loader(command, metadata_file.as_ref(), backend_invocation.tail)?
        } else {
            run_backend_command(command, backend_path)?
        };

        last_exit_code = exit_code;
        if exit_code != 0 {
            let duration = format_duration(started_at.elapsed());
            let _ = writeln!(
                io::stdout(),
                "{}{}",
                warn_text("[fail]"),
                dim_text(&format!(" exit {exit_code} | {duration} | check the log"))
            );
            return Ok(exit_code);
        }
    }

    let duration = format_duration(started_at.elapsed());
    let _ = writeln!(
        io::stdout(),
        "{}{}",
        style("32", "[ok]"),
        dim_text(&format!(" {duration}"))
    );
    Ok(last_exit_code)
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
) -> Result<i32, String> {
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

    let mut renderer = SpinnerRenderer::new().ok();
    let mut cancel_requested = false;
    let mut header_printed = false;
    let mut tail_window = None;
    let mut metadata = if let Some(metadata_file) = metadata_file {
        read_backend_metadata(metadata_file.path())?
    } else {
        None
    };

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
        print_backend_header(metadata)
            .map_err(|error| format!("failed to print command header: {error}"))?;
        print_backend_log_notice(metadata, tail_enabled)
            .map_err(|error| format!("failed to print log location: {error}"))?;
        if tail_enabled {
            tail_window = Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
        }
        header_printed = true;
    }

    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("failed while waiting for backend: {error}"))?
        {
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
                    print_backend_header(metadata)
                        .map_err(|error| format!("failed to print command header: {error}"))?;
                    print_backend_log_notice(metadata, tail_enabled)
                        .map_err(|error| format!("failed to print log location: {error}"))?;
                    if tail_enabled {
                        tail_window = Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
                    }
                }
            }
            if let Some(tail_window) = tail_window.as_mut() {
                tail_window
                    .finish()
                    .map_err(|error| format!("failed to render tailed log: {error}"))?;
                if tail_enabled {
                    tail_window
                        .clear()
                        .map_err(|error| format!("failed to clear tailed log: {error}"))?;
                }
            }
            if let Some(renderer) = renderer.as_mut() {
                renderer.clear_line();
            }
            if tail_enabled && header_printed && renderer.is_some() {
                let _ = write!(io::stdout(), "\u{1b}[1A\r\u{1b}[2K");
                let _ = io::stdout().flush();
            }
            return Ok(summarize_backend_exit(
                status,
                started_at.elapsed(),
                cancel_requested || signal_requested.load(Ordering::Relaxed),
                metadata.as_ref(),
            ));
        }

        if signal_requested.load(Ordering::Relaxed) {
            break;
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
                print_backend_header(metadata)
                    .map_err(|error| format!("failed to print command header: {error}"))?;
                print_backend_log_notice(metadata, tail_enabled)
                    .map_err(|error| format!("failed to print log location: {error}"))?;
                if tail_enabled {
                    tail_window = Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
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
                    cancel_requested = true;
                }
                InputEvent::IncreaseLines => line_delta = 1,
                InputEvent::DecreaseLines => line_delta = -1,
                InputEvent::None => {}
            }
        }

        if let Some(tail_window) = tail_window.as_mut() {
            if line_delta != 0 {
                tail_window.adjust_lines(line_delta);
            }
            tail_window
                .refresh()
                .map_err(|error| format!("failed to render tailed log: {error}"))?;
            if let Some(renderer) = renderer.as_mut() {
                let interrupt_hint = renderer.current_spinner_hint();
                renderer
                    .render_frame_with_hint(
                        child.id(),
                        &tail_hint(&interrupt_hint),
                    )
                    .map_err(|error| format!("failed to render loader: {error}"))?;
            } else {
                thread::sleep(Duration::from_millis(100));
            }
            continue;
        }

        if let Some(renderer) = renderer.as_mut() {
            let hint = renderer.current_spinner_hint();
            renderer
                .render_frame_with_hint(child.id(), &hint)
                .map_err(|error| format!("failed to render loader: {error}"))?;
        } else {
            thread::sleep(Duration::from_millis(100));
        }
    }

    if let Some(tail_window) = tail_window.as_mut() {
        tail_window
            .finish()
            .map_err(|error| format!("failed to render tailed log: {error}"))?;
        if tail_enabled {
            tail_window
                .clear()
                .map_err(|error| format!("failed to clear tailed log: {error}"))?;
        }
    }

    if let Some(renderer) = renderer.as_mut() {
        renderer.clear_line();
    }

    if tail_enabled && header_printed && renderer.is_some() {
        let _ = write!(io::stdout(), "\u{1b}[1A\r\u{1b}[2K");
        let _ = io::stdout().flush();
    }

    let status = child
        .wait()
        .map_err(|error| format!("failed while waiting for backend: {error}"))?;
    Ok(summarize_backend_exit(
        status,
        started_at.elapsed(),
        cancel_requested || signal_requested.load(Ordering::Relaxed),
        metadata.as_ref(),
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

fn print_backend_header(metadata: &BackendMetadata) -> io::Result<()> {
    writeln!(
        io::stdout(),
        "{} {}",
        dim_text("::"),
        accent_text(&format!("makevn {}", metadata.title))
    )
}

fn print_backend_log_notice(metadata: &BackendMetadata, tail_enabled: bool) -> io::Result<()> {
    if tail_enabled {
        return writeln!(
            io::stdout(),
            "{} {} {} {}{}{}",
            dim_text("->"),
            dim_text(&format!("tailing log: {}", metadata.relative_log_path)),
            dim_text("|"),
            dim_text("press "),
            style("97", "+/-"),
            dim_text(" to expand")
        );
    }

    print_backend_log_summary(metadata)
}

fn print_backend_log_summary(metadata: &BackendMetadata) -> io::Result<()> {
    writeln!(
        io::stdout(),
        "{} {}",
        dim_text("::"),
        dim_text(&format!("log: {}", metadata.relative_log_path))
    )
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
) -> i32 {
    let exit_code = exit_code_from_status(status, interrupted);
    let duration = format_duration(elapsed);

    let title = metadata.map(|m| m.title.as_str()).unwrap_or("?");
    let log = metadata.and_then(|m| {
        if m.relative_log_path.is_empty() {
            None
        } else {
            Some(m.relative_log_path.as_str())
        }
    });

    if exit_code == 0 {
        let rest = match log {
            Some(log_path) => format!(" {} | {} | {}", title, duration, log_path),
            None => format!(" {}", title),
        };
        let _ = writeln!(io::stdout(), "{}{}", accent_text("[✓]"), dim_text(&rest));
        return 0;
    }

    let rest = match log {
        Some(log_path) => format!(" {} | {} | {}", title, duration, log_path),
        None => format!(" {}", title),
    };
    let _ = writeln!(io::stdout(), "{}{}", warn_text("[x]"), dim_text(&rest));
    exit_code
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
        libc::kill(pid as libc::pid_t, SIGINT);
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
    (io::stdout().is_terminal() || io::stderr().is_terminal())
        && env::var_os("NO_COLOR").is_none()
        && env::var("TERM").map(|term| term != "dumb").unwrap_or(true)
}

fn style(code: &str, text: &str) -> String {
    if use_color() {
        format!("\u{1b}[{code}m{text}\u{1b}[0m")
    } else {
        text.to_owned()
    }
}

fn terminal_width() -> usize {
    env::var("COLUMNS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(120)
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

fn tail_hint(interrupt_hint: &str) -> String {
    interrupt_hint.to_owned()
}

fn tail_line_text(line: &str) -> String {
    let width = terminal_width().max(8);
    let max_chars = width.saturating_sub(1);
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

    faint_text(&truncated)
}

struct LogTailWindow {
    path: PathBuf,
    file: Option<File>,
    offset: u64,
    pending: Vec<u8>,
    lines: Vec<String>,
    visible_lines: usize,
    rendered_lines: usize,
}

impl LogTailWindow {
    fn new(path: PathBuf) -> Self {
        Self {
            path,
            file: None,
            offset: 0,
            pending: Vec::new(),
            lines: Vec::new(),
            visible_lines: 4,
            rendered_lines: 0,
        }
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

        let clear_lines = self.rendered_lines.max(visible_capacity)
            + usize::from(self.rendered_lines > visible_capacity);
        if self.rendered_lines > 0 {
            write!(io::stdout(), "\u{1b}[{}A", self.rendered_lines)?;
        }

        for index in 0..clear_lines {
            write!(io::stdout(), "\r\u{1b}[2K")?;
            if index + 1 < clear_lines {
                write!(io::stdout(), "\n")?;
            }
        }

        if clear_lines > 1 {
            write!(io::stdout(), "\u{1b}[{}A", clear_lines - 1)?;
        }

        if clear_lines > 0 {
            write!(io::stdout(), "\r")?;
        }

        for line in &self.lines {
            writeln!(io::stdout(), "{}", tail_line_text(line))?;
        }

        for _ in self.lines.len()..visible_capacity {
            writeln!(io::stdout())?;
        }

        io::stdout().flush()?;
        self.rendered_lines = visible_capacity;
        Ok(())
    }

    fn clear(&mut self) -> io::Result<()> {
        if self.rendered_lines == 0 {
            return Ok(());
        }

        let total_lines = self.rendered_lines + 1;

        write!(io::stdout(), "\u{1b}[{}A", total_lines)?;
        for index in 0..=total_lines {
            write!(io::stdout(), "\r\u{1b}[2K")?;
            if index < total_lines {
                write!(io::stdout(), "\n")?;
            }
        }
        write!(io::stdout(), "\u{1b}[{}A\r", total_lines)?;
        io::stdout().flush()?;
        self.rendered_lines = 0;
        Ok(())
    }
}

fn spinner_kitt_frame(frame_index: usize) -> String {
    let width = 8usize;
    let hold_frames = 4usize;
    let forward_frames = width;
    let backward_frames = width - 1;
    let cycle_length = forward_frames + hold_frames + backward_frames + hold_frames;
    let cycle_index = frame_index % cycle_length;
    let pulse_codes = ["38;5;60", "38;5;61", "38;5;62", "38;5;61"];
    let trail_codes = ["38;5;189", "38;5;153", "38;5;111", "38;5;68"];
    let default_code = pulse_codes[frame_index % pulse_codes.len()];
    let (active_position, moving_left, hold_progress) = if cycle_index < forward_frames {
        (width - 1 - cycle_index, true, None)
    } else if cycle_index < forward_frames + hold_frames {
        (0, true, Some(cycle_index - forward_frames))
    } else if cycle_index < forward_frames + hold_frames + backward_frames {
        (cycle_index - forward_frames - hold_frames + 1, false, None)
    } else {
        (
            width - 1,
            false,
            Some(cycle_index - forward_frames - hold_frames - backward_frames),
        )
    };
    let mut output = String::new();

    for index in 0..width {
        let directional_distance = if moving_left {
            index as isize - active_position as isize
        } else {
            active_position as isize - index as isize
        };

        let mut color_index = directional_distance;
        if let Some(progress) = hold_progress {
            color_index += progress as isize;
        }

        if color_index >= 0 && (color_index as usize) < trail_codes.len() {
            output.push_str(&style(trail_codes[color_index as usize], "■"));
        } else {
            if use_color() {
                output.push_str(&style(default_code, "·"));
            } else {
                output.push('.');
            }
        }
    }

    output
}

struct SpinnerRenderer {
    tty: File,
    tty_guard: TtyModeGuard,
    frame: usize,
    frame_interval: Duration,
    next_frame_at: Instant,
    second_escape_deadline: Option<Instant>,
    resource_sampler: ResourceSampler,
}

enum InputEvent {
    None,
    Interrupt,
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
            frame_interval: Duration::from_millis(100),
            next_frame_at: Instant::now(),
            second_escape_deadline: None,
            resource_sampler: ResourceSampler::new(),
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

    fn render_frame_with_hint(&mut self, pid: u32, hint: &str) -> io::Result<()> {
        let now = Instant::now();
        if self.next_frame_at > now {
            thread::sleep(self.next_frame_at - now);
        }

        let resource_text = self.resource_sampler.sample(pid).unwrap_or_default();
        let suffix = if resource_text.is_empty() {
            hint.to_owned()
        } else {
            format!("{} {} {}", dim_text(&resource_text), dim_text("|"), hint)
        };

        write!(
            io::stdout(),
            "\r\u{1b}[2K{}  {}",
            spinner_kitt_frame(self.frame),
            suffix
        )?;
        io::stdout().flush()?;
        self.frame += 1;
        self.next_frame_at = Instant::now() + self.frame_interval;
        Ok(())
    }

    fn clear_line(&mut self) {
        self.clear_frame_line();
        if use_color() {
            let _ = write!(io::stdout(), "\u{1b}[?25h");
        }
        let _ = io::stdout().flush();
    }

    fn clear_frame_line(&mut self) {
        let _ = write!(io::stdout(), "\r\u{1b}[2K");
        let _ = io::stdout().flush();
    }
}

struct ResourceSample {
    cpu_percent: f32,
    rss_kb: u64,
}

struct ResourceSampler {
    last_sample_at: Option<Instant>,
    last_sample: Option<ResourceSample>,
}

impl ResourceSampler {
    fn new() -> Self {
        Self {
            last_sample_at: None,
            last_sample: None,
        }
    }

    fn sample(&mut self, pid: u32) -> io::Result<String> {
        if pid == 0 {
            return Ok(String::new());
        }

        let now = Instant::now();
        if let (Some(last_sample_at), Some(last_sample)) =
            (self.last_sample_at, self.last_sample.as_ref())
        {
            if now.duration_since(last_sample_at) < Duration::from_secs(1) {
                return Ok(format_resource_sample(last_sample));
            }
        }

        let sample = read_resource_sample(pid)?;
        self.last_sample_at = Some(now);
        self.last_sample = Some(sample);
        Ok(format_resource_sample(
            self.last_sample.as_ref().expect("sample just stored"),
        ))
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

fn format_resource_sample(sample: &ResourceSample) -> String {
    format!(
        "cpu {:.1}% | ram {}",
        sample.cpu_percent,
        format_kib(sample.rss_kb)
    )
}

fn format_kib(kib: u64) -> String {
    const MIB: u64 = 1024;
    const GIB: u64 = 1024 * 1024;

    if kib >= GIB {
        return format!("{:.1} GiB", kib as f64 / GIB as f64);
    }

    if kib >= MIB {
        return format!("{:.1} MiB", kib as f64 / MIB as f64);
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

fn install_root(current_exe: &Path) -> Result<PathBuf, String> {
    install_root_with_override(current_exe, env::var_os("MAKEVN_INSTALL_ROOT"))
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

    let bin_dir = current_exe.parent().ok_or_else(|| {
        format!(
            "failed to determine binary directory from {}",
            current_exe.display()
        )
    })?;

    bin_dir.parent().map(Path::to_path_buf).ok_or_else(|| {
        format!(
            "failed to determine install root from {}",
            current_exe.display()
        )
    })
}

fn exit_with_error(message: String) -> ! {
    eprintln!("Error: {message}");
    process::exit(1);
}

fn print_help(with_header: bool) {
    if with_header {
        println!(":: makevn help");
    }

    println!("makevn {}", env!("CARGO_PKG_VERSION"));
    println!();
    println!("Terminal-first workflows for Java Maven repositories.");
    println!();
    println!("If a repository already uses Maven, local build and test flows should be runnable");
    println!("from the terminal without IDE-specific setup. Agents in OpenCode should prefer");
    println!("'makevn' commands over editor-specific instructions.");
    println!();
    println!("Usage:");
    println!("  makevn [--repo PATH] doctor");
    println!("  makevn [--repo PATH] init [--mode MODE] [--dry-run] [--write-make-include]");
    println!("  makevn [--repo PATH] uninstall [--dry-run]");
    println!("  makevn [--repo PATH] profile refresh");
    println!("  makevn [--repo PATH] compile [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] compile-tests [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] validate [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] package [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] build [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] clean [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!(
        "  makevn [--repo PATH] test [--tail] [--name TEST]... [--fast] [-- EXTRA_MAVEN_ARGS...]"
    );
    println!("  makevn [--repo PATH] verify-ut [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] verify-ut-coverage [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] verify-it [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] verify-it-coverage [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] verify [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] verify-changes [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] pr-verify [--tail] [-- EXTRA_MAVEN_ARGS...]");
    println!("  makevn [--repo PATH] docker-up");
    println!("  makevn [--repo PATH] docker-down");
    println!("  makevn [--repo PATH] docker-ps");
    println!("  makevn [--repo PATH] run");
    println!("  makevn [--repo PATH] exec [--context code|karate] -- COMMAND [ARGS...]");
    println!("  makevn [--repo PATH] jdk current");
    println!("  makevn [--repo PATH] jdk list");
    println!();
    println!("Modes:");
    println!("  standalone");
    println!("  make-include");
    println!("  make-bootstrap");
    println!("  auto");
    println!();
    println!("Examples:");
    println!("  makevn doctor");
    println!("  makevn init --mode standalone");
    println!("  makevn profile refresh");
    println!("  makevn compile");
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
    println!("  makevn verify-changes");
    println!("  makevn pr-verify");
    println!("  makevn docker-up");
    println!("  makevn exec -- mvn -q -v");
    println!("  make -f .makevn/makevn.mk vn-doctor");
    println!();
    println!("Notes:");
    println!("  - 'doctor' inspects the repository and recommends the least invasive mode.");
    println!("  - 'standalone' keeps everything under '.makevn/' and leaves root makefiles alone.");
    println!("  - 'make-include' adds optional namespaced 'vn-*' targets without taking over repo-owned targets.");
    println!(
        "  - 'make-bootstrap' is only for repositories that do not already have a make entrypoint."
    );
    println!("  - '--tail' keeps managed-log command output compact and ends each command with ':: log: ...' plus '[ok] <duration>'.");
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
        command_supports_frontend_loader, dim_text, insert_backend_option,
        install_root_with_override, parse_invocation, read_backend_metadata,
        split_command_segments,
        strip_frontend_tail_flag, Action, BackendInvocation,
    };
    use std::env;
    use std::ffi::OsString;
    use std::fs;
    use std::io::Write;
    use std::path::Path;
    use std::process;
    use std::time::{SystemTime, UNIX_EPOCH};

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
    fn normalizes_repo_for_doctor_dispatch() {
        let current_dir = env::current_dir().unwrap();
        let action = parse_invocation(vec![OsString::from("doctor")]).unwrap();

        assert_eq!(
            action,
            Action::DispatchToBackend(vec![BackendInvocation {
                args: vec![
                    OsString::from("doctor"),
                    OsString::from("--repo"),
                    current_dir.into_os_string(),
                ],
                frontend_loader: false,
                tail: false,
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
            vec![
                (
                    OsString::from("test"),
                    vec![OsString::from("--name"), OsString::from("verify-it")],
                ),
            ]
        );
    }

    #[test]
    fn parses_command_sequence_for_backend_dispatch() {
        let current_dir = env::current_dir().unwrap();
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
                        current_dir.clone().into_os_string(),
                    ],
                    frontend_loader: true,
                    tail: true,
                },
                BackendInvocation {
                    args: vec![
                        OsString::from("verify-it"),
                        OsString::from("--repo"),
                        current_dir.into_os_string(),
                    ],
                    frontend_loader: true,
                    tail: true,
                },
            ])
        );
    }

    #[test]
    fn parses_global_tail_prefix_for_command_sequence() {
        let current_dir = env::current_dir().unwrap();
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
                        current_dir.clone().into_os_string(),
                    ],
                    frontend_loader: true,
                    tail: true,
                },
                BackendInvocation {
                    args: vec![
                        OsString::from("verify-it"),
                        OsString::from("--repo"),
                        current_dir.into_os_string(),
                    ],
                    frontend_loader: true,
                    tail: true,
                },
            ])
        );
    }

    #[test]
    fn parses_command_sequence_with_options_per_command() {
        let current_dir = env::current_dir().unwrap();
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
                        current_dir.clone().into_os_string(),
                    ],
                    frontend_loader: true,
                    tail: true,
                },
                BackendInvocation {
                    args: vec![
                        OsString::from("verify-it"),
                        OsString::from("--repo"),
                        current_dir.into_os_string(),
                    ],
                    frontend_loader: true,
                    tail: true,
                },
            ])
        );
    }

    #[test]
    fn keeps_intermediate_tail_local_to_its_command() {
        let current_dir = env::current_dir().unwrap();
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
                        current_dir.clone().into_os_string(),
                    ],
                    frontend_loader: true,
                    tail: true,
                },
                BackendInvocation {
                    args: vec![
                        OsString::from("verify-it"),
                        OsString::from("--repo"),
                        current_dir.into_os_string(),
                    ],
                    frontend_loader: true,
                    tail: false,
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
        assert!(command_supports_frontend_loader(&OsString::from("verify")));
        assert!(!command_supports_frontend_loader(&OsString::from("doctor")));
        assert!(!command_supports_frontend_loader(&OsString::from("run")));
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
        assert_eq!(tail_window.lines, vec![String::from("first"), String::from("second")]);

        let mut file = fs::File::create(&log_path).unwrap();
        file.write_all(b"third\n").unwrap();
        file.flush().unwrap();

        tail_window.read_available().unwrap();
        assert_eq!(tail_window.lines, vec![String::from("third")]);

        fs::remove_file(log_path).unwrap();
    }

    #[test]
    fn log_summary_uses_short_label() {
        assert_eq!(
            format!("{} {}", dim_text("::"), dim_text("log: .makevn/logs/verify-it.log")),
            format!("{} {}", dim_text("::"), dim_text("log: .makevn/logs/verify-it.log"))
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
}
