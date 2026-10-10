use std::collections::{HashMap, HashSet};
use std::env;
use std::ffi::OsString;
use std::fmt;
use std::fs::{self, File};
use std::io::{self, IsTerminal, Read, Seek, SeekFrom, Write};
use std::mem::MaybeUninit;
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;
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

mod docker_resources;
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

    if let Action::InstallOpenCodeAgent = action {
        match install_opencode_agent() {
            Ok(path) => {
                println!("makevn MCP installed for OpenCode");
                println!("  Config: {}", path.display());
                println!("  Restart OpenCode to load the makevn MCP tools.");
                return;
            }
            Err(message) => exit_with_error(message),
        }
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
        Action::InstallOpenCodeAgent => unreachable!(),
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
    InstallOpenCodeAgent,
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

// Completion records survive metadata changes and are scoped to one invocation.
struct BackendPhaseFiles(PathBuf);

impl BackendPhaseFiles {
    fn new() -> Result<Self, String> {
        let temporary = BackendDetailFile::new()?;
        let path = temporary.path().with_extension("phases");
        fs::create_dir(&path).map_err(|error| error.to_string())?;
        Ok(Self(path))
    }

    fn read(&self) -> Vec<CommandSummary> {
        let mut indices: Vec<u32> = fs::read_dir(&self.0)
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .filter_map(|entry| entry.file_name().to_str()?.parse().ok())
            .collect();
        indices.sort_unstable();
        indices
            .into_iter()
            .filter_map(|index| {
                let path = self.0.join(index.to_string());
                let content = fs::read_to_string(&path).ok()?;
                let metadata = parse_backend_metadata(&content)?;
                let value = |key: &str| content.lines().find_map(|line| line.strip_prefix(key));
                let seconds = value("duration_seconds=")?.parse().ok()?;
                let exit_code = value("exit_code=")?.parse().ok()?;
                let mut summary = summary_from_backend_metadata(
                    exit_code,
                    format_duration(Duration::from_secs(seconds)),
                    "karate-all",
                    Some(&metadata),
                );
                summary.detail_lines = fs::read_to_string(path.with_extension("detail"))
                    .unwrap_or_default()
                    .lines()
                    .map(str::to_owned)
                    .collect();
                Some(summary)
            })
            .collect()
    }
}

impl Drop for BackendPhaseFiles {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[derive(Debug)]
struct BackendStderrFile {
    path: PathBuf,
}

impl BackendStderrFile {
    fn new() -> Result<Self, String> {
        let unique_suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| format!("failed to resolve stderr timestamp: {error}"))?
            .as_nanos();
        let path = env::temp_dir().join(format!("makevn-{}-{unique_suffix}.stderr", process::id()));
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for BackendStderrFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
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
    if args.first() == Some(&OsString::from("agent")) {
        return match args.as_slice() {
            [agent, install, client]
                if agent == "agent" && install == "install" && client == "opencode" =>
            {
                Ok(Action::InstallOpenCodeAgent)
            }
            [agent, help]
                if agent == "agent"
                    && matches!(help.to_string_lossy().as_ref(), "--help" | "-h") =>
            {
                Ok(Action::PrintCommandHelp {
                    command: String::from("agent"),
                })
            }
            _ => Err(String::from("Usage: makevn agent install opencode")),
        };
    }

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

fn install_opencode_agent() -> Result<PathBuf, String> {
    let config_root = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .ok_or_else(|| String::from("HOME is not set; cannot locate OpenCode configuration"))?;
    let global_dir = config_root.join("opencode");
    let repo_root = resolve_repo_root(None)?;
    let local_configs = detect_local_opencode_configs(&repo_root);
    if !local_configs.is_empty() {
        println!("Found local OpenCode configurations:");
        for config in &local_configs {
            println!("  {}", config.display());
        }
        if io::stdin().is_terminal() {
            println!("Where should makevn be installed?");
            for (index, config) in local_configs.iter().enumerate() {
                println!("  {}) Local config ({})", index + 1, config.display());
            }
            println!("  {}) Global config", local_configs.len() + 1);
            print!("Select [1]: ");
            io::stdout()
                .flush()
                .map_err(|error| format!("failed to write prompt: {error}"))?;
            let mut selection = String::new();
            io::stdin()
                .read_line(&mut selection)
                .map_err(|error| format!("failed to read selection: {error}"))?;
            let selected = if selection.trim().is_empty() {
                1
            } else {
                selection
                    .trim()
                    .parse::<usize>()
                    .map_err(|_| String::from("Invalid selection"))?
            };
            if let Some(local_config) = selected
                .checked_sub(1)
                .and_then(|index| local_configs.get(index))
            {
                return install_opencode_agent_config(local_config);
            }
            if selected == local_configs.len() + 1 {
                return install_opencode_agent_at(&global_dir);
            }
            return Err(format!(
                "Invalid selection; choose a number from 1 to {}",
                local_configs.len() + 1
            ));
        }
    }
    install_opencode_agent_at(&global_dir)
}

fn install_opencode_agent_at(opencode_dir: &Path) -> Result<PathBuf, String> {
    fs::create_dir_all(opencode_dir).map_err(|error| {
        format!(
            "failed to create OpenCode config directory {}: {error}",
            opencode_dir.display()
        )
    })?;

    let jsonc_path = opencode_dir.join("opencode.jsonc");
    let json_path = opencode_dir.join("opencode.json");
    let config_path = if jsonc_path.is_file() {
        jsonc_path
    } else {
        json_path
    };
    install_opencode_agent_config(&config_path)
}

fn detect_local_opencode_configs(repo_root: &Path) -> Vec<PathBuf> {
    let opencode_dir = repo_root.join(".opencode");
    [
        opencode_dir.join("opencode.jsonc"),
        opencode_dir.join("opencode.json"),
        opencode_dir.join("config.jsonc"),
        opencode_dir.join("config.json"),
    ]
    .into_iter()
    .filter(|path| path.is_file())
    .collect()
}

fn install_opencode_agent_config(config_path: &Path) -> Result<PathBuf, String> {
    let original = read_opencode_config(config_path)?;
    let mut config: serde_json::Value = serde_json::from_str(&original)
        .or_else(|_| serde_json::from_str(&strip_jsonc_comments(&original)))
        .map_err(|error| format!("failed to parse {}: {error}", config_path.display()))?;
    let original_config = config.clone();
    configure_opencode_mcp(&mut config, config_path)?;
    if config == original_config {
        return Ok(config_path.to_path_buf());
    }
    let updated = serde_json::to_string_pretty(&config)
        .map_err(|error| format!("failed to serialize OpenCode config: {error}"))?;

    write_opencode_config(config_path, &updated)?;
    Ok(config_path.to_path_buf())
}

fn configure_opencode_mcp(
    config: &mut serde_json::Value,
    config_path: &Path,
) -> Result<(), String> {
    let root = config.as_object_mut().ok_or_else(|| {
        format!(
            "OpenCode config must be a JSON object: {}",
            config_path.display()
        )
    })?;
    let mcp = root
        .entry("mcp")
        .or_insert_with(|| serde_json::Value::Object(serde_json::Map::new()))
        .as_object_mut()
        .ok_or_else(|| String::from("OpenCode config field 'mcp' must be a JSON object"))?;
    mcp.insert(
        String::from("makevn"),
        serde_json::json!({
            "type": "local",
            "command": ["makevn-mcp"],
            "enabled": true,
            "timeout": 900000
        }),
    );
    Ok(())
}

fn read_opencode_config(config_path: &Path) -> Result<String, String> {
    if let Some(parent) = config_path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "failed to create OpenCode config directory {}: {error}",
                parent.display()
            )
        })?;
    }
    let original = if config_path.is_file() {
        fs::read_to_string(config_path)
            .map_err(|error| format!("failed to read {}: {error}", config_path.display()))?
    } else {
        String::from("{}")
    };
    Ok(original)
}

fn write_opencode_config(config_path: &Path, updated: &str) -> Result<(), String> {
    if config_path.is_file() {
        let backup_path = PathBuf::from(format!("{}.makevn.bak", config_path.display()));
        fs::copy(config_path, &backup_path)
            .map_err(|error| format!("failed to back up {}: {error}", config_path.display()))?;
    }
    fs::write(config_path, format!("{updated}\n"))
        .map_err(|error| format!("failed to write {}: {error}", config_path.display()))?;
    let written = fs::read_to_string(config_path)
        .map_err(|error| format!("failed to verify {}: {error}", config_path.display()))?;
    serde_json::from_str::<serde_json::Value>(&written)
        .map_err(|error| format!("written OpenCode config is invalid: {error}"))?;
    Ok(())
}

fn strip_jsonc_comments(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'"' => {
                let end = jsonc_string_end(bytes, index + 1);
                output.extend_from_slice(&bytes[index..end]);
                index = end;
            }
            b'/' if bytes.get(index + 1) == Some(&b'/') => {
                index = jsonc_line_comment_end(bytes, index + 2);
            }
            b'/' if bytes.get(index + 1) == Some(&b'*') => {
                index = jsonc_block_comment_end(bytes, index + 2);
            }
            byte => {
                output.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8(output).expect("removing ASCII comment tokens preserves UTF-8")
}

fn jsonc_string_end(bytes: &[u8], mut index: usize) -> usize {
    while index < bytes.len() {
        if bytes[index] == b'\\' && index + 1 < bytes.len() {
            index += 2;
        } else if bytes[index] == b'"' {
            return index + 1;
        } else {
            index += 1;
        }
    }
    bytes.len()
}

fn jsonc_line_comment_end(bytes: &[u8], mut index: usize) -> usize {
    while index < bytes.len() && bytes[index] != b'\n' {
        index += 1;
    }
    index
}

fn jsonc_block_comment_end(bytes: &[u8], mut index: usize) -> usize {
    while index + 1 < bytes.len() {
        if bytes[index] == b'*' && bytes[index + 1] == b'/' {
            return index + 2;
        }
        index += 1;
    }
    bytes.len()
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

        if consume_command_option(
            &arg,
            &mut forwarding_passthrough_args,
            &mut option_expects_value,
        ) {
            current_args.push(arg);
            continue;
        }

        if starts_command_segment(&arg) {
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

fn consume_command_option(
    arg: &OsString,
    passthrough: &mut bool,
    expects_value: &mut bool,
) -> bool {
    if *passthrough || *expects_value {
        *expects_value = false;
        return true;
    }
    if arg == "--" {
        *passthrough = true;
        return true;
    }
    if command_option_takes_value(arg) {
        *expects_value = true;
        return true;
    }
    false
}

fn starts_command_segment(arg: &OsString) -> bool {
    is_top_level_command(arg)
        && !COMMAND_SEQUENCE_BREAKERS.contains(&arg.to_string_lossy().as_ref())
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
    if is_top_level_command(command)
        && trailing_args
            .iter()
            .any(|arg| matches!(arg.to_string_lossy().as_ref(), "--help" | "-h"))
    {
        return Ok(CommandValidation::Valid);
    }

    match command.to_string_lossy().as_ref() {
        "compile"
        | "test-compile"
        | "compile-tests"
        | "validate"
        | "package"
        | "clean"
        | "build"
        | "verify-ut"
        | "verify-ut-coverage"
        | "verify-it"
        | "verify-it-coverage"
        | "verify"
        | "verify-changes-preview"
        | "verify-changes"
        | "pr-verify"
        | "format"
        | "checkstyle"
        | "karate-test"
        | "karate-all"
        | "mutation" => {
            validate_maven_passthrough_args(command, trailing_args)?;
            Ok(CommandValidation::Valid)
        }
        "help" | "init" | "refresh" | "uninstall" | "test" | "coverage" | "coverage-changes"
        | "crap" | "crap-changes" | "docker-up" | "docker-down" | "docker-ps" | "docker-stats"
        | "docker-ps-required" | "karate-docker-up" | "karate-docker-down" | "run-app"
        | "run-app-bg" | "stop-app" | "run" => Ok(CommandValidation::Valid),
        "doctor" => {
            if let Some(extra_arg) = trailing_args.iter().find(|arg| *arg != "--compact") {
                Err(format!("Unknown doctor option: {}", Lossy(extra_arg)))
            } else {
                Ok(CommandValidation::Valid)
            }
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
        backend_invocations.push(build_backend_invocation(
            &repo_root,
            command,
            trailing_args,
            global_tail,
            global_compact,
        )?);
    }

    Ok(backend_invocations)
}

fn build_backend_invocation(
    repo_root: &Path,
    command: OsString,
    trailing_args: Vec<OsString>,
    global_tail: bool,
    global_compact: bool,
) -> Result<BackendInvocation, String> {
    validate_command(&command, &trailing_args)?;
    let frontend_loader = command_supports_frontend_loader(&command);
    let (trailing_args, command_tail) = strip_frontend_tail_flag(&command, trailing_args)?;
    if global_tail && !frontend_loader {
        return Err(format!(
            "--tail is only supported for managed-log run commands, not {}",
            Lossy(&command)
        ));
    }
    // Unsupported global tail was rejected above.
    let tail = command_tail || global_tail;
    let mut backend_args = Vec::with_capacity(trailing_args.len() + 3);
    backend_args.push(command);
    backend_args.push(OsString::from("--repo"));
    backend_args.push(repo_root.as_os_str().to_owned());
    if global_compact {
        backend_args.push(OsString::from("--compact"));
    }
    backend_args.extend(trailing_args);
    Ok(BackendInvocation {
        args: backend_args,
        frontend_loader,
        tail,
        compact: global_compact,
    })
}

fn is_top_level_command(arg: &OsString) -> bool {
    matches!(
        arg.to_string_lossy().as_ref(),
        "help"
            | "doctor"
            | "init"
            | "uninstall"
            | "profile"
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
            | "crap"
            | "crap-changes"
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
        "--name"
            | "--threshold"
            | "--max-warnings"
            | "--jacoco-xml"
            | "--base"
            | "--tag"
            | "--compose"
            | "--module"
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
        let _ = fs::remove_file(self.path.with_extension("resources"));
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
            | "crap"
            | "crap-changes"
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

fn interactive_presentation(
    stdin_tty: bool,
    stdout_tty: bool,
    stderr_tty: bool,
    agent: bool,
    dumb: bool,
) -> bool {
    stdin_tty && stdout_tty && stderr_tty && !agent && !dumb
}

fn frontend_loader_is_available() -> bool {
    interactive_presentation(
        io::stdin().is_terminal(),
        io::stdout().is_terminal(),
        io::stderr().is_terminal(),
        agent_output_mode(),
        env::var("TERM").is_ok_and(|term| term == "dumb"),
    )
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
    let use_dashboard = frontend_loader_is_available();

    // Output size and interactive presentation are independent: compact human
    // runs retain color and telemetry, while agents never enter terminal mode.
    let loader_available = frontend_loader_is_available();
    let detail_file = if loader_available {
        BackendDetailFile::new().ok()
    } else {
        None
    };
    let mut renderer = None;

    for mut backend_invocation in backend_invocations {
        let fallback_title = backend_invocation
            .args
            .first()
            .map(|arg| arg.to_string_lossy().into_owned())
            .unwrap_or_else(|| String::from("command"));
        let use_frontend_loader = loader_available;
        let state_command = !backend_invocation.frontend_loader;
        // Keep the live block across commands, including metadata startup waits.
        if use_frontend_loader && renderer.is_none() {
            renderer = SpinnerRenderer::new_with_input(true).ok();
        }
        let captured_stdout =
            if use_frontend_loader && (state_command || backend_invocation.compact) {
                Some(BackendStderrFile::new()?)
            } else {
                None
            };
        let prompt_sync = if use_frontend_loader && state_command {
            Some(BackendDetailFile::new()?)
        } else {
            None
        };
        // Managed-log commands expose backend metadata, including in compact
        // runs. State commands reject this internal option.
        let metadata_file = if backend_invocation.frontend_loader || use_frontend_loader {
            let metadata_file = BackendMetadataFile::new()?;
            if backend_invocation.frontend_loader {
                insert_backend_option(
                    &mut backend_invocation.args,
                    "--metadata-out",
                    metadata_file.path().as_os_str().to_os_string(),
                );
            } else {
                write_state_metadata(
                    metadata_file.path(),
                    &fallback_title,
                    &backend_invocation.args[2],
                )?;
            }
            Some(metadata_file)
        } else {
            None
        };

        let phase_files = if fallback_title == "karate-all"
            || (use_frontend_loader && fallback_title == "doctor")
        {
            Some(BackendPhaseFiles::new()?)
        } else {
            None
        };
        let mut command = process::Command::new("bash");
        if let Some(phases) = &phase_files {
            command.env("MAKEVN_BACKEND_PHASE_DIR", &phases.0);
        }
        command.arg(backend_path);
        command.args(&backend_invocation.args);
        command.env("MAKEVN_BIN_PATH", current_exe);
        command.env("MAKEVN_INSTALL_ROOT", install_root);
        command.env("MAKEVN_FRONTEND", "rust");
        command.env("MAKEVN_FRONTEND_VERSION", makevn_version());
        command.env("MAKEVN_VERSION", makevn_version());
        if state_command {
            if let Some(metadata) = &metadata_file {
                command.env("MAKEVN_FRONTEND_STATE_METADATA_OUT", metadata.path());
            }
        }
        if let Some(metadata) = metadata_file.as_ref().filter(|_| use_frontend_loader) {
            command.env(
                "MAKEVN_FRONTEND_RESOURCE_SCOPE_OUT",
                metadata.path().with_extension("resources"),
            );
        }
        if !loader_available {
            command.env("NO_COLOR", "1");
        }

        let run_result = if use_frontend_loader {
            if !state_command {
                command.process_group(0);
            }
            if let Some(output) = &captured_stdout {
                command.stdout(
                    File::create(output.path())
                        .map_err(|error| format!("failed to capture backend output: {error}"))?,
                );
            } else {
                command.stdout(process::Stdio::null());
            }
            // Backend stderr must not write into the live dashboard: Git and
            // other tools can emit warnings that move the terminal cursor and
            // strand a spinner row above the final summary.
            let stderr_file = BackendStderrFile::new()?;
            let stderr_writer = File::create(stderr_file.path())
                .map_err(|error| format!("failed to capture backend stderr: {error}"))?;
            if state_command {
                // Keep stderr a TTY so existing interactive configuration prompts
                // retain their behavior. The prompt handshake pauses the loader.
                command.env(
                    "MAKEVN_FRONTEND_PROMPT_SYNC",
                    prompt_sync.as_ref().unwrap().path(),
                );
            } else {
                command.stderr(process::Stdio::from(stderr_writer));
            }
            command.env("MAKEVN_FRONTEND_OWNS_LOADER", "1");
            if let Some(df) = detail_file.as_ref() {
                command.env("MAKEVN_BACKEND_DETAIL_OUT", df.path());
            }
            let result = run_backend_with_loader(
                command,
                metadata_file.as_ref(),
                backend_invocation.tail,
                &fallback_title,
                started_at,
                &completed_summaries,
                renderer.as_mut(),
                detail_file.as_ref(),
                phase_files.as_ref(),
                prompt_sync.as_ref(),
            );
            if !state_command {
                if let Some(output) = &captured_stdout {
                    replay_backend_output(output.path(), renderer.as_mut(), false);
                }
            }
            replay_backend_output(stderr_file.path(), renderer.as_mut(), true);
            if result.is_err() {
                if let Some(renderer) = renderer.as_mut() {
                    renderer.clear_line();
                }
            }
            result?
        } else {
            let elapsed_before = started_at.elapsed();
            let exit_code = run_backend_command(command, backend_path)?;
            let metadata = metadata_file
                .as_ref()
                .map(|metadata_file| read_backend_metadata(metadata_file.path()))
                .transpose()?
                .flatten();
            BackendRunResult {
                exit_code,
                summary: summary_from_backend_metadata(
                    exit_code,
                    format_duration(started_at.elapsed().saturating_sub(elapsed_before)),
                    &fallback_title,
                    metadata.as_ref(),
                ),
            }
        };

        // Snapshot detail lines into the summary then clear for the next command.
        let stdout_details: Vec<String> = captured_stdout
            .as_ref()
            .filter(|_| state_command)
            .and_then(|output| fs::read_to_string(output.path()).ok())
            .unwrap_or_default()
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(str::to_owned)
            .collect();
        let mut detail_lines = detail_file
            .as_ref()
            .map(|df| df.read_lines())
            .unwrap_or_default();
        detail_lines.extend(stdout_details.iter().cloned());
        if let Some(df) = detail_file.as_ref() {
            df.clear();
        }

        last_exit_code = run_result.exit_code;
        let failure_hint = read_failure_hint(run_result.summary.log_path.as_deref());
        let mut summary = run_result.summary;
        summary.detail_lines = detail_lines;
        let mut phases = phase_files
            .as_ref()
            .map(|files| files.read())
            .unwrap_or_default();
        if let Some(last_phase) = phases.last_mut() {
            last_phase.detail_lines.extend(stdout_details);
        }
        let needs_fallback = phases
            .last()
            .map(|phase| phase.exit_code != last_exit_code)
            .unwrap_or(true);
        completed_summaries.extend(phases);
        if needs_fallback {
            completed_summaries.push(summary);
        }

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

// Only external output needs to take ownership of the live terminal block.
fn replay_backend_output(path: &Path, renderer: Option<&mut SpinnerRenderer>, stderr: bool) {
    if stderr {
        let _ = stream_backend_output(path, renderer, &mut io::stderr().lock());
    } else {
        let _ = stream_backend_output(path, renderer, &mut io::stdout().lock());
    }
}

fn stream_backend_output(
    path: &Path,
    renderer: Option<&mut SpinnerRenderer>,
    output: &mut impl Write,
) -> io::Result<u64> {
    let mut file = File::open(path)?;
    if file.metadata()?.len() == 0 {
        return Ok(0);
    }
    if let Some(renderer) = renderer {
        renderer.clear_line();
    }
    io::copy(&mut file, output)
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

fn summary_from_backend_metadata(
    exit_code: i32,
    duration: String,
    fallback_title: &str,
    metadata: Option<&BackendMetadata>,
) -> CommandSummary {
    CommandSummary {
        title: metadata
            .map(|metadata| metadata.title.clone())
            .unwrap_or_else(|| fallback_title.to_owned()),
        duration,
        log_path: metadata
            .map(|metadata| metadata.log_path.clone())
            .filter(|path| !path.is_empty()),
        relative_log_path: metadata
            .map(|metadata| metadata.relative_log_path.clone())
            .filter(|path| !path.is_empty()),
        exit_code,
        detail_lines: Vec::new(),
    }
}

fn docker_connection_failed(lower: &str) -> bool {
    lower.contains("cannot connect to the docker daemon")
        || lower.contains("is the docker daemon running")
        || lower.contains("error during connect") && lower.contains("docker")
}

fn read_failure_hint(log_path: Option<&str>) -> Option<String> {
    let content = fs::read_to_string(log_path?).ok()?;
    let lower = content.to_ascii_lowercase();
    if docker_connection_failed(&lower) {
        return Some("Docker is unavailable. Start Docker Desktop or your Docker runtime (e.g. `colima start`), check `docker info`, then retry".to_owned());
    }
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
    phase_files: Option<&BackendPhaseFiles>,
    prompt_sync: Option<&BackendDetailFile>,
) -> Result<BackendRunResult, String> {
    let started_at = Instant::now();
    if let Some(renderer) = renderer.as_mut() {
        renderer.begin_backend();
        renderer.configure_resource_source(
            fallback_title,
            metadata_file.map(|m| m.path().with_extension("resources")),
        );
    }
    let mut child = command.spawn().map_err(|error| {
        format!(
            "failed to launch backend {}: {error}",
            command.get_program().to_string_lossy()
        )
    })?;

    // State backends stay in the foreground group so canonical prompt reads
    // are not stopped by SIGTTIN. Managed-log backends own a separate group.
    let signal_target = if prompt_sync.is_some() {
        child.id() as libc::pid_t
    } else {
        -(child.id() as libc::pid_t)
    };
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
        if tail_active {
            if let Some(renderer) = renderer.as_mut() {
                renderer.clear_frame_line();
            }
        }
        if tail_active {
            tail_window = Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
        } else if let Some(renderer) = renderer.as_mut() {
            if let Some(df) = detail_file {
                current_detail_lines = df.read_lines();
            }
            let hint = renderer.current_metadata_hint(metadata);
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
        if let Some(sync) = prompt_sync {
            if fs::read_to_string(sync.path()).ok().as_deref() == Some("pause\n") {
                if let Some(renderer) = renderer.as_mut() {
                    renderer.pause();
                }
                fs::write(sync.path(), "paused\n")
                    .map_err(|error| format!("failed to pause loader: {error}"))?;
            } else if fs::read_to_string(sync.path()).ok().as_deref() == Some("resume\n") {
                if let Some(renderer) = renderer.as_mut() {
                    renderer
                        .resume()
                        .map_err(|error| format!("failed to resume loader: {error}"))?;
                }
                fs::write(sync.path(), "running\n")
                    .map_err(|error| format!("failed to resume loader: {error}"))?;
            }
        }
        let mut live_summaries = completed_summaries.to_vec();
        if let Some(phases) = phase_files {
            live_summaries.extend(phases.read());
        }
        let completed_summaries = live_summaries.as_slice();
        if let Some(metadata_file) = metadata_file {
            let latest_metadata = read_backend_metadata(metadata_file.path())?;
            if latest_metadata.is_some() && latest_metadata != metadata {
                metadata = latest_metadata;
                if tail_active {
                    if let Some(metadata) = metadata.as_ref() {
                        LogTailWindow::follow_log(
                            &mut tail_window,
                            PathBuf::from(&metadata.log_path),
                        );
                    }
                }
            }
        }

        if let (Some(renderer), Some(metadata)) = (renderer.as_mut(), metadata.as_ref()) {
            renderer.configure_resource_source(
                &metadata.command,
                metadata_file.map(|m| m.path().with_extension("resources")),
            );
        }
        if let Some(df) = detail_file {
            let latest = df.read_lines();
            if latest != current_detail_lines {
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
                    if tail_active {
                        if let Some(renderer) = renderer.as_mut() {
                            renderer.clear_frame_line();
                        }
                    }
                    if tail_active {
                        tail_window = Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
                    } else if let Some(renderer) = renderer.as_mut() {
                        let hint = renderer.current_metadata_hint(metadata);
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
                interrupt_backend(signal_target);
                cancel_requested = true;
                cancel_requested_at = Some(Instant::now());
            }
        }

        if let Some(requested_at) = cancel_requested_at {
            let elapsed = requested_at.elapsed();
            if elapsed > Duration::from_secs(4) {
                let _ = unsafe { libc::kill(signal_target, libc::SIGKILL) };
                break;
            } else if elapsed > Duration::from_secs(2) {
                let _ = unsafe { libc::kill(signal_target, libc::SIGTERM) };
            }
        }

        if !header_printed {
            if metadata.is_none() {
                if let Some(metadata_file) = metadata_file {
                    metadata = read_backend_metadata(metadata_file.path())?;
                }
            }

            if let Some(metadata) = metadata.as_ref() {
                if tail_active {
                    if let Some(renderer) = renderer.as_mut() {
                        renderer.clear_frame_line();
                    }
                }
                if tail_active {
                    tail_window = Some(LogTailWindow::new(PathBuf::from(&metadata.log_path)));
                } else if let Some(renderer) = renderer.as_mut() {
                    let hint = renderer.current_metadata_hint(metadata);
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
                    interrupt_backend(signal_target);
                    #[cfg(unix)]
                    unsafe {
                        libc::kill(signal_target, SIGTERM);
                    }
                    cancel_requested = true;
                    cancel_requested_at = Some(Instant::now());
                }
                InputEvent::StartTail => {
                    if !tail_active {
                        if let Some(metadata) = metadata
                            .as_ref()
                            .filter(|metadata| !metadata.log_path.is_empty())
                        {
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
            // Tail owns the screen only after metadata identifies its log.
            if !tail_active || metadata.is_none() {
                let hint = match metadata.as_ref() {
                    Some(metadata) if metadata.log_path.is_empty() => {
                        renderer.current_spinner_hint()
                    }
                    _ => renderer.current_dashboard_hint(),
                };
                if let Some(metadata) = metadata.as_ref() {
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
                } else {
                    let hint = renderer.current_spinner_hint();
                    renderer
                        .render_dashboard(
                            child.id(),
                            global_started_at.elapsed(),
                            completed_summaries,
                            &[],
                            &pending_backend_metadata(fallback_title),
                            &hint,
                        )
                        .map_err(|error| format!("failed to render loader: {error}"))?;
                }
            } else {
                let hint = renderer.current_spinner_hint();
                renderer
                    .render_frame_with_hint(child.id(), &hint)
                    .map_err(|error| format!("failed to render loader: {error}"))?;
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

// State commands use the same metadata renderer, without granting --tail or
// changing the backend's public managed-log options.
fn write_state_metadata(path: &Path, title: &str, repo: &OsString) -> Result<(), String> {
    let repo = repo.to_string_lossy().replace('\n', " ");
    let metadata = format!("command={title}\nrepo={repo}\ncwd={repo}\nlog_path=\nrelative_log_path=\ncommand_display=makevn {title}\ntitle={title}\n");
    fs::write(path, metadata).map_err(|error| format!("failed to write state metadata: {error}"))
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

    Ok(parse_backend_metadata(&content))
}

fn parse_backend_metadata(content: &str) -> Option<BackendMetadata> {
    let fields: std::collections::HashMap<_, _> = content
        .lines()
        .filter_map(|line| line.split_once('='))
        .collect();
    let (
        Some(command),
        Some(repo),
        Some(cwd),
        Some(log_path),
        Some(relative_log_path),
        Some(command_display),
        Some(title),
    ) = (
        fields.get("command"),
        fields.get("repo"),
        fields.get("cwd"),
        fields.get("log_path"),
        fields.get("relative_log_path"),
        fields.get("command_display"),
        fields.get("title"),
    )
    else {
        return None;
    };
    Some(BackendMetadata {
        command: (*command).to_owned(),
        repo: (*repo).to_owned(),
        cwd: (*cwd).to_owned(),
        log_path: (*log_path).to_owned(),
        relative_log_path: (*relative_log_path).to_owned(),
        command_display: (*command_display).to_owned(),
        title: (*title).to_owned(),
        context: fields.get("context").map(|value| (*value).to_owned()),
    })
}

fn backend_header_line(metadata: &BackendMetadata) -> String {
    format!(
        "{} {}",
        active_action_text("[•]"),
        active_action_text(&format!("makevn {}", metadata.title))
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
        "Worked  for {}",
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

fn pending_command_line(title: &str) -> String {
    format!("makevn {title}")
}

fn pending_backend_metadata(title: &str) -> BackendMetadata {
    BackendMetadata {
        command: title.to_owned(),
        repo: String::new(),
        cwd: String::new(),
        log_path: String::new(),
        relative_log_path: String::new(),
        command_display: pending_command_line(title),
        title: format!("{title} (starting)"),
        context: None,
    }
}

fn running_command_line(metadata: &BackendMetadata) -> String {
    if metadata.relative_log_path.is_empty() {
        format!(
            "{} {}",
            active_action_text("[•]"),
            active_action_text(&format!("makevn {}", metadata.title))
        )
    } else {
        format!(
            "{} {} {} {}",
            active_action_text("[•]"),
            active_action_text(&format!("makevn {}", metadata.title)),
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

fn interrupt_backend(target: libc::pid_t) {
    #[cfg(unix)]
    unsafe {
        libc::kill(target, SIGINT);
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
    frontend_loader_is_available() && env::var_os("NO_COLOR").is_none()
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

fn active_action_color_code(colorterm: Option<&str>, term: Option<&str>) -> &'static str {
    if colorterm.is_some_and(|value| {
        value.eq_ignore_ascii_case("truecolor") || value.eq_ignore_ascii_case("24bit")
    }) || term.is_some_and(|value| value.ends_with("-direct"))
    {
        // Dominant reference text color, converted to sRGB: #e3c168.
        "38;2;227;193;104"
    } else {
        "33"
    }
}

fn active_action_text(text: &str) -> String {
    style(
        active_action_color_code(
            env::var("COLORTERM").ok().as_deref(),
            env::var("TERM").ok().as_deref(),
        ),
        text,
    )
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

    fn follow_log(window: &mut Option<Self>, path: PathBuf) {
        let window = window.get_or_insert_with(|| Self::new(path.clone()));
        window.switch_log(path);
    }

    fn switch_log(&mut self, path: PathBuf) {
        if self.path == path {
            return;
        }
        self.path = path;
        self.file = None;
        self.offset = 0;
        self.pending.clear();
        self.lines.clear();
        // Keep the painted rows and chosen height: the next render must erase
        // the previous phase before drawing the new log in the same block.
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
        if let (Some(file), Ok(current)) = (&self.file, fs::metadata(&self.path)) {
            let opened = file.metadata()?;
            if (opened.dev(), opened.ino()) != (current.dev(), current.ino()) {
                self.file = None;
                self.offset = 0;
                self.pending.clear();
                self.lines.clear();
            }
        }
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

        clear_tail_rows(&mut io::stdout(), rows)?;
        self.rendered_lines = 0;
        self.rendered_width = terminal_width().max(8);
        self.rendered_line_widths.clear();
        Ok(())
    }
}

fn clear_tail_rows(writer: &mut impl Write, rows: usize) -> io::Result<()> {
    write!(writer, "\u{1b}[{}A", rows)?;
    for index in 0..=rows {
        write!(writer, "\r\u{1b}[2K")?;
        if index < rows {
            write!(writer, "\n")?;
        }
    }
    write!(writer, "\u{1b}[{}A\r", rows)?;
    writer.flush()
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
            output.push_str(&spinner_background(
                pulse_codes[frame_index % pulse_codes.len()],
                frame_index % pulse_codes.len(),
                load,
            ));
        }
    }

    output
}

fn spinner_background(code: Option<&str>, pulse_index: usize, load: f32) -> String {
    match code {
        Some(code) if use_color() => spinner_pulse_style(code, pulse_index, load),
        Some(_) => ".".to_owned(),
        None => " ".to_owned(),
    }
}

fn spinner_pulse_style(code: &str, pulse_index: usize, load: f32) -> String {
    if load <= 0.01 {
        style(code, "·")
    } else {
        let cool = pulse_color(pulse_index);
        let warm = Rgb::new(72, 54, 48);
        style(&rgb_code(interpolate_color(cool, warm, load * 0.55)), "·")
    }
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
    tty_guard: Option<TtyModeGuard>,
    paused: bool,
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
    fn new_with_input(interactive_input: bool) -> io::Result<Self> {
        let tty = File::options().read(true).write(true).open("/dev/tty")?;
        let tty_guard = if interactive_input {
            Some(TtyModeGuard::new(&tty)?)
        } else {
            None
        };

        if use_color() {
            write!(io::stdout(), "\u{1b}[?25l")?;
            io::stdout().flush()?;
        }

        Ok(Self {
            tty,
            tty_guard,
            paused: false,
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

    // Reset command-local state without erasing the retained terminal block.
    fn begin_backend(&mut self) {
        self.second_escape_deadline = None;
        self.resource_sampler = ResourceSampler::new();
        self.resource_history = ResourceHistory::new();
        self.resource_history_revision = 0;
        self.cpu_visual_load = 0.0;
        self.ram_visual_load = 0.0;
        self.resource_visual_load = 0.0;
    }

    fn pause(&mut self) {
        self.clear_line();
        self.show_cursor();
        self.tty_guard = None;
        self.paused = true;
    }

    fn resume(&mut self) -> io::Result<()> {
        self.tty_guard = Some(TtyModeGuard::new(&self.tty)?);
        self.paused = false;
        self.next_frame_at = Instant::now();
        if use_color() {
            write!(io::stdout(), "\u{1b}[?25l")?;
            io::stdout().flush()?;
        }
        Ok(())
    }

    fn poll_input(&mut self) -> io::Result<InputEvent> {
        if self.tty_guard.is_none() {
            return Ok(InputEvent::None);
        }
        let mut buffer = [0_u8; 1];
        match self.tty.read(&mut buffer) {
            Ok(1) => Ok(decode_spinner_input(
                buffer[0],
                &mut self.second_escape_deadline,
            )),
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

    fn current_metadata_hint(&mut self, metadata: &BackendMetadata) -> String {
        if metadata.log_path.is_empty() {
            self.current_spinner_hint()
        } else {
            self.current_dashboard_hint()
        }
    }

    fn render_frame_with_hint(&mut self, pid: u32, hint: &str) -> io::Result<()> {
        if self.paused {
            thread::sleep(Duration::from_millis(50));
            return Ok(());
        }
        let line = self.frame_line_with_hint(pid, hint)?;
        // Before backend metadata arrives this is the only live row. Clipping
        // keeps it single-line so the detailed dashboard can replace it cleanly.
        let line = status_line_text_for_width(&line, terminal_width().max(8));
        write!(io::stdout(), "\r\u{1b}[2K{}", line)?;
        io::stdout().flush()?;
        if let Some(width) = self.rendered_block_line_widths.last_mut() {
            *width = visible_char_count(&line);
        }
        Ok(())
    }

    fn frame_line_with_hint(&mut self, pid: u32, hint: &str) -> io::Result<String> {
        wait_until_next_frame(self.next_frame_at);

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
            .unwrap_or_else(|| self.unavailable_resource_text());
        let resource_text = self.resource_sampler.scoped_text(
            resource_text,
            resource_sample.is_some().then_some(self.cpu_visual_load),
        );
        let suffix = spinner_resource_suffix(&resource_text, hint);

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
        if self.paused {
            thread::sleep(Duration::from_millis(50));
            return Ok(());
        }
        wait_until_next_frame(self.next_frame_at);

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
            .unwrap_or_else(|| self.unavailable_resource_text());
        let resource_text = self.resource_sampler.scoped_text(
            resource_text,
            resource_sample.is_some().then_some(self.cpu_visual_load),
        );
        let spinner_suffix = spinner_resource_suffix(&resource_text, hint);

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

        let mut stdout = io::stdout().lock();
        self.clear_dynamic_block()?;
        let mut replacement = String::new();
        for (index, line) in lines.iter().enumerate() {
            if index + 1 == lines.len() {
                replacement.push_str(&format!("\r\u{1b}[2K{line}"));
            } else {
                replacement.push_str(&format!("\r\u{1b}[2K{line}\n"));
            }
        }
        stdout.write_all(replacement.as_bytes())?;
        stdout.flush()?;
        self.rendered_block_line_widths =
            lines.iter().map(|line| visible_char_count(line)).collect();
        self.frame += 1;
        self.next_frame_at = Instant::now() + self.frame_interval();
        Ok(())
    }

    fn configure_resource_source(&mut self, title: &str, scope: Option<PathBuf>) {
        let revision = self.resource_sampler.revision();
        self.resource_sampler.configure_docker(title, scope);
        if revision != self.resource_sampler.revision() {
            self.resource_history = ResourceHistory::new();
            self.resource_history_revision = self.resource_sampler.revision();
            self.cpu_visual_load = 0.0;
            self.ram_visual_load = 0.0;
            self.resource_visual_load = 0.0;
        }
    }

    fn update_resource_visuals(&mut self, sample: Option<&ResourceSample>) {
        let target_cpu_load = sample.map(cpu_metric_load).unwrap_or(0.0);
        let target_ram_load = sample.map(ram_metric_load).unwrap_or(0.0);
        self.cpu_visual_load += (target_cpu_load - self.cpu_visual_load) * 0.06;
        self.ram_visual_load += (target_ram_load - self.ram_visual_load) * 0.06;
        let target_load = sample.map(resource_visual_load).unwrap_or(0.0);
        self.resource_visual_load += (target_load - self.resource_visual_load) * 0.06;
    }

    fn unavailable_resource_text(&self) -> String {
        if self.resource_sampler.docker.is_some() {
            format_unavailable_resource_metrics(&self.resource_history)
        } else {
            String::new()
        }
    }

    fn sync_resource_history(&mut self, sample: Option<&ResourceSample>) {
        if self.resource_sampler.docker.is_some() {
            self.resource_history.tick(Instant::now(), sample);
            return;
        }
        self.resource_history_revision = self.resource_history.sync_sample(
            self.resource_history_revision,
            self.resource_sampler.revision(),
            sample,
        );
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

fn decode_spinner_input(byte: u8, escape_deadline: &mut Option<Instant>) -> InputEvent {
    match byte {
        0x1b => {
            let now = Instant::now();
            if escape_deadline.is_some_and(|deadline| deadline > now) {
                *escape_deadline = None;
                InputEvent::Interrupt
            } else {
                *escape_deadline = Some(now + Duration::from_secs(3));
                InputEvent::None
            }
        }
        b't' | b'T' => InputEvent::StartTail,
        b'+' => InputEvent::IncreaseLines,
        b'-' => InputEvent::DecreaseLines,
        _ => InputEvent::None,
    }
}

fn wait_until_next_frame(next_frame_at: Instant) {
    let now = Instant::now();
    if next_frame_at > now {
        thread::sleep(next_frame_at - now);
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
    docker: Option<docker_resources::DockerSampler>,
    docker_scope: Option<(String, PathBuf)>,
    last_pid: Option<u32>,
    last_sample_at: Option<Instant>,
    last_sample: Option<ResourceSample>,
    sample_revision: u64,
}

impl ResourceSampler {
    const SAMPLE_INTERVAL: Duration = Duration::from_secs(2);

    fn new() -> Self {
        Self {
            docker: None,
            docker_scope: None,
            last_pid: None,
            last_sample_at: None,
            last_sample: None,
            sample_revision: 0,
        }
    }

    fn configure_docker(&mut self, title: &str, scope: Option<PathBuf>) {
        let scope = scope
            .filter(|_| docker_resources::is_docker_phase(title))
            .map(|path| (title.to_owned(), path));
        if scope == self.docker_scope {
            return;
        }
        self.last_sample = None;
        self.last_sample_at = None;
        self.sample_revision += 1;
        self.docker = scope
            .as_ref()
            .map(|(_, path)| docker_resources::DockerSampler::new(path.clone()));
        self.docker_scope = scope;
    }

    fn sample(&mut self, pid: u32) -> io::Result<Option<ResourceSample>> {
        if let Some(docker) = self.docker.as_mut() {
            let (sample, changed) = docker.poll();
            self.sample_revision += u64::from(changed);
            return Ok(sample);
        }
        if self.last_pid != Some(pid) {
            self.last_pid = Some(pid);
            self.last_sample_at = None;
            self.last_sample = None;
        }
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

    fn scoped_text(&self, text: String, cpu_load: Option<f32>) -> String {
        if self.docker.is_none() {
            return text;
        }
        let label = cpu_load
            .map(|load| adaptive_metric_text("ctr", load))
            .unwrap_or_else(|| dim_text("ctr"));
        let metrics = if text.is_empty() {
            format_unavailable_resource_metrics(&ResourceHistory::new())
        } else {
            text
        };
        format!("{label} {metrics}")
    }

    fn revision(&self) -> u64 {
        self.sample_revision
    }
}

struct ResourceHistory {
    cpu_percent: Vec<Option<f32>>,
    rss_kb: Vec<Option<u64>>,
    last_tick: Option<Instant>,
}

impl ResourceHistory {
    const WIDTH: usize = 6;

    fn new() -> Self {
        Self {
            cpu_percent: Vec::with_capacity(Self::WIDTH),
            rss_kb: Vec::with_capacity(Self::WIDTH),
            last_tick: None,
        }
    }

    fn push(&mut self, sample: ResourceSample) {
        self.push_slot(Some(&sample));
    }

    fn push_slot(&mut self, sample: Option<&ResourceSample>) {
        push_ring_value(
            &mut self.cpu_percent,
            sample.map(|s| s.cpu_percent),
            Self::WIDTH,
        );
        push_ring_value(&mut self.rss_kb, sample.map(|s| s.rss_kb), Self::WIDTH);
    }

    // The Docker graph is a time axis, not a count of asynchronous probe results.
    fn tick(&mut self, now: Instant, sample: Option<&ResourceSample>) {
        let Some(previous) = self.last_tick else {
            self.last_tick = Some(now);
            self.push_slot(sample);
            return;
        };
        let ticks =
            now.duration_since(previous).as_secs() / ResourceSampler::SAMPLE_INTERVAL.as_secs();
        if ticks == 0 {
            return;
        }
        for _ in 1..ticks.min(Self::WIDTH as u64) {
            self.push_slot(None);
        }
        self.push_slot(sample);
        self.last_tick = Some(previous + ResourceSampler::SAMPLE_INTERVAL * ticks as u32);
    }

    fn sync_sample(
        &mut self,
        previous_revision: u64,
        revision: u64,
        sample: Option<&ResourceSample>,
    ) -> u64 {
        if revision == previous_revision {
            return previous_revision;
        }
        if let Some(sample) = sample {
            self.push(*sample);
        }
        revision
    }
}

fn spinner_resource_suffix(resource_text: &str, hint: &str) -> String {
    if resource_text.is_empty() {
        hint.to_owned()
    } else {
        format!("{} {} {}", resource_text, dim_text("|"), hint)
    }
}

fn read_resource_sample(root_pid: u32) -> io::Result<ResourceSample> {
    let output = process::Command::new("ps")
        .args(["-axo", "pid=,ppid=,%cpu=,rss="])
        .output()?;
    Ok(parse_ps_resource_sample(
        root_pid,
        output.status.success(),
        &String::from_utf8_lossy(&output.stdout),
    ))
}

fn parse_ps_resource_sample(root_pid: u32, success: bool, stdout: &str) -> ResourceSample {
    if !success {
        return ResourceSample {
            cpu_percent: 0.0,
            rss_kb: 0,
        };
    }

    let mut parent_by_pid = HashMap::new();
    let mut metrics_by_pid = HashMap::new();

    for line in stdout.lines() {
        let Some((pid, ppid, cpu_percent, rss_kb)) = parse_ps_resource_row(line) else {
            continue;
        };

        parent_by_pid.insert(pid, ppid);
        metrics_by_pid.insert(pid, (cpu_percent, rss_kb));
    }

    sum_descendant_metrics(root_pid, &parent_by_pid, &metrics_by_pid)
}

fn sum_descendant_metrics(
    root_pid: u32,
    parent_by_pid: &HashMap<u32, u32>,
    metrics_by_pid: &HashMap<u32, (f32, u64)>,
) -> ResourceSample {
    let mut descendants = HashSet::from([root_pid]);
    let mut changed = true;
    while changed {
        changed = false;
        for (&pid, &ppid) in parent_by_pid {
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

    ResourceSample {
        cpu_percent,
        rss_kb,
    }
}

fn parse_ps_resource_row(line: &str) -> Option<(u32, u32, f32, u64)> {
    let fields = line.split_whitespace().collect::<Vec<_>>();
    if fields.len() != 4 {
        return None;
    }

    Some((
        fields[0].parse().ok()?,
        fields[1].parse().ok()?,
        fields[2].replace(',', ".").parse().ok()?,
        fields[3].parse().ok()?,
    ))
}

#[cfg(test)]
#[path = "resource_sample_test.rs"]
mod resource_sample_test;

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

fn format_unavailable_resource_metrics(history: &ResourceHistory) -> String {
    let cpu = sparkline_f32(&history.cpu_percent, ResourceHistory::WIDTH, 250.0);
    let ram = sparkline_u64(&history.rss_kb, ResourceHistory::WIDTH);
    dim_text(&format!("cpu {cpu} {:>5} | ram {ram}  {:>5}", "—", "—"))
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

fn sparkline_f32(values: &[Option<f32>], width: usize, max_value: f32) -> String {
    if values.is_empty() {
        return " ".repeat(width);
    }
    let normalized = values
        .iter()
        .map(|value| {
            value
                .map(|v| (v / max_value).clamp(0.0, 1.0))
                .unwrap_or(f32::NAN)
        })
        .collect::<Vec<_>>();
    sparkline_from_normalized(&normalized, width)
}

fn sparkline_u64(values: &[Option<u64>], width: usize) -> String {
    if values.is_empty() {
        return " ".repeat(width);
    }
    let peak = values.iter().flatten().copied().max().unwrap_or(0);
    if peak == 0 {
        return " ".repeat(width);
    }
    let normalized = values
        .iter()
        .map(|value| {
            value
                .map(|v| (v as f32 / peak as f32).clamp(0.0, 1.0))
                .unwrap_or(f32::NAN)
        })
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
        sparkline.push(if value.is_nan() { ' ' } else { SPARKS[index] });
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
        "agent" => Some(("makevn agent install opencode", "Install the makevn MCP server in the global OpenCode configuration.", &[])),
        "doctor" => Some(("makevn [--repo PATH] doctor [--compact] [--reset-config]", "Inspect repository setup and makevn configuration.", &["--compact  Print brief, noninteractive setup advice", "--reset-config  Back up settings and ask setup questions again (interactive CLI only)"])),
        "init" => Some(("makevn [--repo PATH] init [--dry-run] [--force]", "Initialize .makevn configuration for the repository.", &["--dry-run  Show what would change without writing files", "--force    Refresh existing generated files"])),
        "uninstall" => Some(("makevn [--repo PATH] uninstall [--dry-run]", "Remove makevn local repository state.", &["--dry-run  Show what would be removed"])),
        "refresh" => Some(("makevn [--repo PATH] refresh [--dry-run]", "Refresh initialization while preserving user configuration.", &["--dry-run  Show what would change without writing files"])),
        "profile" => Some(("makevn [--repo PATH] profile refresh", "Refresh detected repository profile information.", &[])),
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
        "crap" => Some(("makevn [--repo PATH] crap [install-analyzer] [--jacoco-xml PATH] [--threshold SCORE] [--max-warnings COUNT]", "Calculate Java CRAP metrics from existing JaCoCo XML coverage.", &["install-analyzer  Download and verify the pinned crap4java release", "--jacoco-xml      Use a specific existing JaCoCo XML report", "--threshold       CRAP score warning threshold (default: 8)", "--max-warnings    Fail when the warning count exceeds this ratchet"])),
        "crap-changes" => Some(("makevn [--repo PATH] crap-changes [--base REF]", "Show CRAP for changed production Java methods using existing JaCoCo coverage.", &["--base  Override the detected base branch/ref"])),
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
    let usages = [
        ("compile", "makevn [--repo PATH] [--compact] compile [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("test-compile", "makevn [--repo PATH] [--compact] test-compile [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("compile-tests", "makevn [--repo PATH] [--compact] compile-tests [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("validate", "makevn [--repo PATH] [--compact] validate [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("package", "makevn [--repo PATH] [--compact] package [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("build", "makevn [--repo PATH] [--compact] build [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("clean", "makevn [--repo PATH] [--compact] clean [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify-ut", "makevn [--repo PATH] [--compact] verify-ut [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify-ut-coverage", "makevn [--repo PATH] [--compact] verify-ut-coverage [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify-it", "makevn [--repo PATH] [--compact] verify-it [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify-it-coverage", "makevn [--repo PATH] [--compact] verify-it-coverage [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify", "makevn [--repo PATH] [--compact] verify [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify-changes", "makevn [--repo PATH] [--compact] verify-changes [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"),
        ("pr-verify", "makevn [--repo PATH] [--compact] pr-verify [--tail] [-- EXTRA_MAVEN_ARGS...]"),
    ];
    let usage = usages.iter().find(|(name, _)| *name == command)?.1;
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
    println!("  makevn agent install opencode");
    println!("  makevn [--repo PATH] doctor");
    println!("  makevn [--repo PATH] init [--dry-run] [--force]");
    println!("  makevn [--repo PATH] refresh [--dry-run]");
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
    println!("  makevn [--repo PATH] crap [--jacoco-xml PATH] [--threshold SCORE] [--max-warnings COUNT]");
    println!("  makevn [--repo PATH] crap-changes [--base REF]");
    println!("  makevn [--repo PATH] crap install-analyzer");
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
    println!("  makevn [--repo PATH] jdk current");
    println!("  makevn [--repo PATH] jdk list");
    println!();
    println!("Examples:");
    println!("  makevn doctor");
    println!("  makevn init");
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
    println!("  makevn crap");
    println!("  makevn crap-changes");
    println!("  makevn pr-verify");
    println!("  makevn format --apply");
    println!("  makevn checkstyle --module domain --verbose");
    println!("  makevn docker-up");
    println!("  makevn docker-stats");
    println!("  makevn karate-test");
    println!("  makevn karate-test --tag @smoke");
    println!("  makevn run-app-bg");
    println!("  makevn stop-app");
    println!();
    println!("Notes:");
    println!("  - 'doctor' inspects the repository before and after initialization.");
    println!("  - 'init' creates '.makevn/' without inspecting or modifying root Makefiles.");
    println!("  - '--compact' shortens reports; MAKEVN_AGENT_OUTPUT=1 disables TTY presentation for agents.");
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
#[path = "main_test.rs"]
mod tests;
