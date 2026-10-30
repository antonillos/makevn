pub(super) fn command_help(
    command: &str,
) -> Option<(&'static str, &'static str, &'static [&'static str])> {
    match command {
        "agent install" => Some(("makevn agent install <opencode|codex> [--scope global|project]", "Register MCP and five workflow skills for an agent client.", &["--scope global|project  Select configuration and skills scope"])),
        "agent status" => Some(("makevn agent status <opencode|codex> --scope global|project", "Inspect agent registration without changes.", &["--scope global|project  Required configuration and skills scope"])),
        "agent upgrade" => Some(("makevn agent upgrade [--scope global|project]", "Upgrade existing MCP and workflow skill integration, preferring project scope.", &["--scope global|project  Override detected scope"])),
        "profile refresh" => Some(("makevn [--repo PATH] profile refresh", "Refresh detected repository profile information.", &[])),
        "jdk current" => Some(("makevn [--repo PATH] jdk current", "Show the selected JDK installation.", &[])),
        "jdk list" => Some(("makevn [--repo PATH] jdk list", "List discovered JDK installations.", &[])),
        "crap install-analyzer" => Some(("makevn [--repo PATH] crap install-analyzer", "Download and verify the pinned crap4java release.", &[])),
        "execution-cleanup" => Some(("makevn execution-cleanup [--retention-days DAYS] [--dry-run]", "Remove expired execution records and owned logs. Outputs JSON counts and candidate paths.", &["--retention-days DAYS  Retention period (MAKEVN_RETENTION_DAYS or 3 days)", "--dry-run  List candidates without deleting files"])),
        "help" => Some(("makevn help", "Print the full makevn help.", &[])),
        "agent" => Some(("makevn agent <install|status> <opencode|codex> [--scope global|project] | makevn agent upgrade [--scope global|project]", "Register MCP and five workflow skills, upgrade the existing integration (project before global), or inspect registration without changes. Installation does not prove a running client loaded a skill.", &["--scope global|project  Select configuration and skills scope; status requires it."])),
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
        "clean" => maven_command_help("clean", "Clean Maven build output.", true),
        "test" => Some(("makevn [--repo PATH] [--compact] test [--tail] [--name TEST]... [--fast] [-- EXTRA_MAVEN_ARGS...]", "Run tests with optional filtering.", &["--tail                              Start in interactive log tail mode", "--compact                           Use compact non-interactive output", "--name TEST                         Test class name or comma-separated names", "--fast                              Skip compilation when sources have not changed"])),
        "verify-ut" => maven_command_help("verify-ut", "Run unit-test-only verification.", false),
        "verify-ut-coverage" => maven_command_help("verify-ut-coverage", "Run unit-test-only verification with coverage.", false),
        "verify-it" => maven_command_help("verify-it", "Run integration-test-only verification.", false),
        "verify-it-coverage" => maven_command_help("verify-it-coverage", "Run integration-test-only verification with coverage.", false),
        "verify" => maven_command_help("verify", "Run full combined verification.", false),
        "verify-changes-preview" => Some(("makevn [--repo PATH] verify-changes-preview [--focused|--exhaustive]", "Preview changed-code scope without Maven; focused by default. For user-requested faster local feedback, explain --focused limitations and use the same mode in preview and execution. A large preparation reactor does not mean its test suites run.", &["--focused  Preview focused owner suites and selected tests (default)", "--exhaustive  Preview exhaustive changed-code verification"])),
        "verify-changes" => maven_command_help("verify-changes", "Verify changed-code scope; focused by default, --exhaustive is explicit. --focused prepares dependencies without UT/IT then verifies production owner suites and selected changed tests without -am; not a full integration/coverage gate. Use the same mode as preview and report its scope.", false),
        "coverage" => Some(("makevn [--repo PATH] coverage [--threshold PCT]", "Check the latest aggregate coverage report.", &["--threshold  Required coverage percentage"])),
        "coverage-changes" => Some(("makevn [--repo PATH] coverage-changes [--threshold PCT] [--overall-threshold PCT] [--verbose]", "Check incremental and per-module coverage.", &["--threshold          Per-module coverage percentage", "--overall-threshold  Overall coverage percentage", "--verbose            Print detailed coverage output"])),
        "crap" => Some(("makevn [--repo PATH] crap [install-analyzer] [--jacoco-xml PATH] [--threshold SCORE] [--max-warnings COUNT]", "Calculate Java CRAP metrics from existing JaCoCo XML coverage.", &["install-analyzer  Download and verify the pinned crap4java release", "--jacoco-xml      Use a specific existing JaCoCo XML report", "--threshold       CRAP score warning threshold (default: 8)", "--max-warnings    Fail when the warning count exceeds this ratchet"])),
        "crap-changes" => Some(("makevn [--repo PATH] crap-changes [--base REF]", "Show CRAP for changed production Java methods using existing JaCoCo coverage.", &["--base  Override the detected base branch/ref"])),
        "pr-verify" => maven_command_help("pr-verify", "Run a local PR-style verification flow.", false),
        "format" => Some(("makevn [--repo PATH] [--compact] format [--tail] [--apply] [-- EXTRA_MAVEN_ARGS...]", "Check or apply code formatting.", &["--tail     Start in interactive log tail mode", "--compact  Use compact non-interactive output", "--apply    Apply formatting changes"])),
        "checkstyle" => Some(("makevn [--repo PATH] [--compact] checkstyle [--tail] [--module MODULE] [--verbose] [-- EXTRA_MAVEN_ARGS...]", "Run Checkstyle code style checks.", &["--tail     Start in interactive log tail mode", "--compact  Use compact non-interactive output", "--module   Maven module to check", "--verbose  Print detailed output"])),
        "docker-up" => tail_command_help("docker-up", "Start boot Docker services while preserving volumes."),
        "docker-down" => tail_command_help("docker-down", "Stop boot Docker services while preserving volumes."),
        "docker-reset" => Some(("makevn [--repo PATH] docker-reset [--tail]", "Delete the selected boot Compose volumes and restart its services. Requires explicit reset authorization; never prunes global volumes.", &["--tail  Start in interactive log tail mode"])),
        "docker-ps" => tail_command_help("docker-ps", "List boot Docker containers."),
        "docker-stats" => tail_command_help("docker-stats", "Show Docker CPU and memory stats."),
        "docker-ps-required" => Some(("makevn [--repo PATH] docker-ps-required [--tail] [--compose boot|karate] [--wait-seconds N]", "Validate required Docker services are running and healthy.", &["--tail          Start in interactive log tail mode", "--compose       Compose profile: boot or karate", "--wait-seconds  Seconds to wait for services"])),
        "karate-docker-up" => tail_command_help("karate-docker-up", "Start Karate E2E Docker services while preserving volumes."),
        "karate-docker-down" => tail_command_help("karate-docker-down", "Stop Karate E2E Docker services while preserving volumes."),
        "karate-docker-reset" => Some(("makevn [--repo PATH] karate-docker-reset [--tail]", "Delete the selected Karate E2E Compose volumes and restart its services. Requires explicit reset authorization; never prunes global volumes.", &["--tail  Start in interactive log tail mode"])),
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

pub(super) fn maven_command_help(
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
        ("clean", "makevn [--repo PATH] [--compact] clean [--tail] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify-ut", "makevn [--repo PATH] [--compact] verify-ut [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify-ut-coverage", "makevn [--repo PATH] [--compact] verify-ut-coverage [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify-it", "makevn [--repo PATH] [--compact] verify-it [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify-it-coverage", "makevn [--repo PATH] [--compact] verify-it-coverage [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify", "makevn [--repo PATH] [--compact] verify [--tail] [-- EXTRA_MAVEN_ARGS...]"),
        ("verify-changes", "makevn [--repo PATH] [--compact] verify-changes [--tail] [--focused|--exhaustive] [-- EXTRA_MAVEN_ARGS...]"),
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
            "--clean-generated-contract-targets  Remove stale generated sources after Maven clean",
            "--                                  Forward remaining arguments to Maven",
        ];
        Some((usage, description, options))
    } else {
        Some((usage, description, base_options))
    }
}

pub(super) fn tail_command_help(
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

use std::io::{self, IsTerminal};

const COMMANDS: &[&str] = &[
    "agent",
    "doctor",
    "init",
    "refresh",
    "uninstall",
    "profile",
    "compile",
    "test-compile",
    "compile-tests",
    "validate",
    "package",
    "build",
    "clean",
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
    "crap-changes",
    "pr-verify",
    "format",
    "checkstyle",
    "docker-up",
    "docker-down",
    "docker-reset",
    "docker-ps",
    "docker-stats",
    "docker-ps-required",
    "karate-docker-up",
    "karate-docker-down",
    "karate-docker-reset",
    "karate-test",
    "karate-all",
    "run-app",
    "run-app-bg",
    "stop-app",
    "run",
    "jdk",
    "mutation",
    "execution-cleanup",
    "help",
];
const GLOBAL_FLAGS: &[&str] = &[
    "--repo PATH  Select the repository root",
    "--compact  Use compact non-interactive output",
    "--tail  Start managed commands in interactive log tail mode",
    "-h, --help  Print help for this command",
    "--version  Print the MakeVN version",
];

pub(super) fn print_help(_with_header: bool) {
    print!("{}", render_root(color_enabled()));
}

pub(super) fn print_command_help(command: &str) {
    match render_command(command, color_enabled()) {
        Some(help) => print!("{help}"),
        None => super::exit_with_error(format!("Unknown command: {command}")),
    }
}

pub(super) fn print_mcp_help() {
    print!("{}", page(
        "Model Context Protocol server for MakeVN. Run without arguments from an MCP client; communication uses stdio.",
        "makevn-mcp",
        &[],
        &[],
        &["-h, --help  Print help", "--version  Print the MakeVN version"],
        color_enabled(),
    ));
}

fn color_enabled() -> bool {
    use std::env;
    io::stdout().is_terminal()
        && env::var_os("NO_COLOR").is_none()
        && env::var("TERM").as_deref() != Ok("dumb")
        && env::var("MAKEVN_AGENT_OUTPUT").as_deref() != Ok("1")
}

fn paint(text: &str, code: &str, color: bool) -> String {
    if color {
        format!("\x1b[{code}m{text}\x1b[0m")
    } else {
        text.to_owned()
    }
}

fn syntax(text: &str, literal: &str, color: bool) -> String {
    text.split_inclusive(' ')
        .map(|part| {
            let token = part.trim_end();
            let code = if token.trim_start_matches('[').starts_with('-') {
                "38;5;155"
            } else if token.starts_with('<') || token.chars().any(|c| c.is_ascii_uppercase()) {
                "38;5;245"
            } else {
                literal
            };
            format!("{}{}", paint(token, code, color), &part[token.len()..])
        })
        .collect()
}

fn rows(output: &mut String, heading: &str, entries: &[&str], literal: &str, color: bool) {
    if entries.is_empty() {
        return;
    }
    output.push_str(&format!("\n{}\n", paint(heading, "1", color)));
    let entries: Vec<_> = entries
        .iter()
        .map(|entry| entry.split_once("  ").unwrap_or((entry, "")))
        .collect();
    let width = entries
        .iter()
        .map(|(name, _)| name.len())
        .max()
        .unwrap_or(0);
    for (name, description) in entries {
        output.push_str(&format!(
            "  {}{:padding$}  {}\n",
            syntax(name, literal, color),
            "",
            description.trim(),
            padding = width - name.len()
        ));
    }
}

fn page(
    description: &str,
    usage: &str,
    arguments: &[&str],
    flags: &[&str],
    globals: &[&str],
    color: bool,
) -> String {
    let mut output = format!(
        "{}\n  {description}\n\n{}\n  {}\n",
        paint("DESCRIPTION", "1", color),
        paint("USAGE", "1", color),
        syntax(usage, "38;5;147", color)
    );
    rows(&mut output, "ARGUMENTS", arguments, "38;5;245", color);
    rows(&mut output, "FLAGS", flags, "38;5;155", color);
    rows(&mut output, "GLOBAL FLAGS", globals, "38;5;155", color);
    output
}

fn render_root(color: bool) -> String {
    let commands: Vec<_> = COMMANDS
        .iter()
        .filter_map(|name| {
            let (_, description, _) = command_help(name)?;
            Some(format!(
                "{name}  {}",
                description.split(". ").next().unwrap_or(description)
            ))
        })
        .collect();
    let commands: Vec<_> = commands.iter().map(String::as_str).collect();
    let mut output = page(
        "Terminal-first workflows for Java Maven repositories.",
        "makevn [GLOBAL FLAGS] <COMMAND> [FLAGS]",
        &[],
        &[],
        GLOBAL_FLAGS,
        color,
    );
    rows(&mut output, "COMMANDS", &commands, "38;5;147", color);
    output.push_str("\nRun makevn <command> --help for command usage and flags.\n");
    output
}

fn render_command(command: &str, color: bool) -> Option<String> {
    let (usage, description, flags) = command_help(command)?;
    let mut flags: Vec<_> = flags
        .iter()
        .copied()
        .filter(|flag| !flag.starts_with("--compact ") && !flag.starts_with("--tail "))
        .collect();
    if command == "verify-changes" {
        flags.extend([
            "--focused  Verify owner suites and selected tests (default)",
            "--exhaustive  Run exhaustive changed-code verification",
        ]);
    }
    let children = subcommands(command);
    let globals = global_flags(command);
    let arguments: &[&str] = if matches!(command, "agent install" | "agent status") {
        &["<CLIENT>  Agent client: opencode or codex"]
    } else {
        &[]
    };
    let mut output = page(description, usage, arguments, &flags, globals, color);
    rows(&mut output, "SUBCOMMANDS", children, "38;5;147", color);
    Some(output)
}

fn global_flags(command: &str) -> &[&str] {
    if command.starts_with("agent") || command == "execution-cleanup" {
        &GLOBAL_FLAGS[3..4]
    } else {
        &GLOBAL_FLAGS[..4]
    }
}

fn subcommands(command: &str) -> &[&str] {
    match command {
        "agent" => &[
            "install  Register MCP and workflow skills",
            "status  Inspect registration",
            "upgrade  Upgrade existing integration",
        ],
        "profile" => &["refresh  Refresh detected repository profile"],
        "jdk" => &["current  Show selected JDK", "list  List discovered JDKs"],
        "crap" => &["install-analyzer  Download and verify the pinned analyzer"],
        _ => &[],
    }
}

#[cfg(test)]
#[path = "cli_help_test.rs"]
mod tests;

pub(super) fn requested_command(args: &[std::ffi::OsString]) -> Result<Option<String>, String> {
    let args = help_words(args);
    let help_command = args.first().is_some_and(|arg| *arg == "help");
    let help_flag = args
        .last()
        .is_some_and(|arg| *arg == "--help" || *arg == "-h");
    if !help_command && !help_flag {
        return Ok(None);
    }
    let start = usize::from(help_command);
    let end = args.len() - usize::from(help_flag);
    resolve_help(&args[start..end], help_command)
}

fn help_words(args: &[std::ffi::OsString]) -> Vec<&str> {
    let mut words = Vec::new();
    let mut args = args.iter().filter_map(|arg| arg.to_str());
    while let Some(arg) = args.next() {
        match arg {
            "--repo" if words.is_empty() => {
                args.next();
            }
            "--compact" | "--tail" if words.is_empty() => {}
            "--" => return Vec::new(),
            "-h" | "--help" => {
                words.push(arg);
                break;
            }
            _ => words.push(arg),
        }
    }
    words
}

fn resolve_help(words: &[&str], explicit: bool) -> Result<Option<String>, String> {
    let Some(parent) = words.first() else {
        return Ok(None);
    };
    let nested = words.get(1).map(|child| format!("{parent} {child}"));
    let command = nested
        .filter(|name| command_help(name).is_some())
        .unwrap_or_else(|| (*parent).to_owned());
    if command_help(&command).is_none() || (explicit && words.join(" ") != command) {
        return Err(format!("Unknown command: {}", words.join(" ")));
    }
    Ok(Some(command))
}
