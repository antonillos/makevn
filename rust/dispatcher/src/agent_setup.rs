//! Client setup is separate from Java repository initialization.
use crate::agent_transaction::error_text;
use crate::{agent_skills, agent_transaction};
use std::env;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, IsTerminal, Write};
use std::path::{Path, PathBuf};
use toml_edit::{value, DocumentMut, InlineTable, Item, Table};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Client {
    OpenCode,
    Codex,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Scope {
    Global,
    Project,
}
#[derive(Debug, Eq, PartialEq)]
pub struct Request {
    pub client: Client,
    pub scope: Option<Scope>,
    pub status: bool,
}
const USAGE: &str = "Usage: makevn agent <install|status> <opencode|codex> [--scope global|project]; status requires --scope";

pub fn parse(args: &[OsString]) -> Result<Request, String> {
    let [action, client, remaining @ ..] = args else {
        return Err(USAGE.into());
    };
    let status = parse_action(action)?;
    let scope = parse_scope(remaining)?;
    if status && scope.is_none() {
        return Err(USAGE.into());
    }
    Ok(Request {
        client: parse_client(client)?,
        scope,
        status,
    })
}

fn parse_action(action: &OsString) -> Result<bool, String> {
    match action.to_str() {
        Some("install") => Ok(false),
        Some("status") => Ok(true),
        _ => Err(USAGE.into()),
    }
}

fn parse_client(client: &OsString) -> Result<Client, String> {
    match client.to_str() {
        Some("opencode") => Ok(Client::OpenCode),
        Some("codex") => Ok(Client::Codex),
        _ => Err(USAGE.into()),
    }
}

fn parse_scope(args: &[OsString]) -> Result<Option<Scope>, String> {
    match args {
        [] => Ok(None),
        [flag, scope] if flag == "--scope" => match scope.to_str() {
            Some("global") => Ok(Some(Scope::Global)),
            Some("project") => Ok(Some(Scope::Project)),
            _ => Err(USAGE.into()),
        },
        _ => Err(USAGE.into()),
    }
}

pub fn run(request: &Request) -> Result<(), String> {
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or("HOME is not set")?;
    let repo = crate::resolve_repo_root(None)?;
    let config_home = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or(home.join(".config"));
    let codex_home = env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or(home.join(".codex"));
    let exe = env::current_exe().map_err(error_text)?;
    let source = agent_skills::source(&crate::install_root(&exe)?);
    execute(request, &home, &repo, &config_home, &codex_home, &source)
}

fn execute(
    request: &Request,
    home: &Path,
    repo: &Path,
    config_home: &Path,
    codex_home: &Path,
    source: &Path,
) -> Result<(), String> {
    let global = global_config(request.client, config_home, codex_home);
    let (scope, config) = select_config(request, repo, &global)?;
    if scope == Scope::Project && crate::find_git_root(repo).is_none() {
        return Err(format!(
            "Project scope requires a Git worktree: {}",
            repo.display()
        ));
    }
    let target = skills_target(scope, home, repo);
    println!(
        "Client: {:?}; scope: {:?}\nConfig: {}\nSkills: {}\nDistributed resources: {}",
        request.client,
        scope,
        config.display(),
        target.display(),
        source.display()
    );
    if request.status {
        println!(
            "Skills status: {}",
            agent_skills::status(&source, &target, crate::makevn_version())
        );
        println!("MCP status: {}", config_status(request.client, &config));
        println!("Client discovery/loading is unverified. Check the client's available skills and explicitly load each skill.");
        return Ok(());
    }
    install(
        request.client,
        &config,
        &source,
        &target,
        crate::makevn_version(),
    )?;
    println!(
        "Registered MCP and skills: {}",
        agent_skills::NAMES.join(", ")
    );
    println!("Restart/reload {:?}; inspect available skills and load one explicitly. Project Codex configuration requires a trusted project.", request.client);
    Ok(())
}

fn global_config(client: Client, config_home: &Path, codex_home: &Path) -> PathBuf {
    match client {
        Client::OpenCode => opencode_config(&config_home.join("opencode")),
        Client::Codex => codex_home.join("config.toml"),
    }
}

fn skills_target(scope: Scope, home: &Path, repo: &Path) -> PathBuf {
    match scope {
        Scope::Global => home.join(".agents/skills"),
        Scope::Project => repo.join(".agents/skills"),
    }
}

fn project_config(client: Client, repo: &Path) -> PathBuf {
    match client {
        Client::OpenCode => local_configs(repo)
            .into_iter()
            .next()
            .unwrap_or(repo.join(".opencode/opencode.json")),
        Client::Codex => repo.join(".codex/config.toml"),
    }
}

fn opencode_config(dir: &Path) -> PathBuf {
    let jsonc = dir.join("opencode.jsonc");
    if jsonc.is_file() {
        jsonc
    } else {
        dir.join("opencode.json")
    }
}

fn local_configs(repo: &Path) -> Vec<PathBuf> {
    [
        ".opencode/opencode.jsonc",
        ".opencode/opencode.json",
        ".opencode/config.jsonc",
        ".opencode/config.json",
        "opencode.jsonc",
        "opencode.json",
    ]
    .iter()
    .map(|name| repo.join(name))
    .filter(|path| path.is_file())
    .collect()
}

fn select_config(
    request: &Request,
    repo: &Path,
    global: &Path,
) -> Result<(Scope, PathBuf), String> {
    match request.scope {
        Some(Scope::Project) => Ok((Scope::Project, project_config(request.client, repo))),
        Some(Scope::Global) => Ok((Scope::Global, global.to_path_buf())),
        None if request.client == Client::OpenCode && io::stdin().is_terminal() => choose_opencode(
            repo,
            global,
            &mut io::stdin().lock(),
            &mut io::stdout().lock(),
        ),
        None => Ok((Scope::Global, global.to_path_buf())),
    }
}

fn choose_opencode(
    repo: &Path,
    global: &Path,
    input: &mut impl io::BufRead,
    output: &mut impl Write,
) -> Result<(Scope, PathBuf), String> {
    let configs = local_configs(repo);
    if configs.is_empty() {
        return Ok((Scope::Global, global.to_path_buf()));
    }
    write_choices(&configs, output)?;
    let selected = read_choice(input)?;
    if selected == configs.len() + 1 {
        return Ok((Scope::Global, global.to_path_buf()));
    }
    let config = selected
        .checked_sub(1)
        .and_then(|i| configs.get(i))
        .ok_or("Invalid selection")?;
    Ok((Scope::Project, config.clone()))
}

fn write_choices(configs: &[PathBuf], output: &mut impl Write) -> Result<(), String> {
    writeln!(output, "Where should makevn be installed?").map_err(error_text)?;
    for (i, config) in configs.iter().enumerate() {
        writeln!(output, "  {}) Local config ({})", i + 1, config.display()).map_err(error_text)?;
    }
    writeln!(output, "  {}) Global config", configs.len() + 1).map_err(error_text)?;
    write!(output, "Select [1]: ").map_err(error_text)?;
    output.flush().map_err(error_text)?;
    Ok(())
}

fn read_choice(input: &mut impl io::BufRead) -> Result<usize, String> {
    let mut answer = String::new();
    input.read_line(&mut answer).map_err(error_text)?;
    let selected = if answer.trim().is_empty() {
        1
    } else {
        answer
            .trim()
            .parse::<usize>()
            .map_err(|_| "Invalid selection")?
    };
    Ok(selected)
}

fn opencode_document(text: &str) -> Result<serde_json::Value, String> {
    // JSONC allows trailing commas in addition to comments.
    let clean = crate::strip_jsonc_comments(text);
    let bytes = clean.as_bytes();
    let mut output = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'"' {
            let end = crate::jsonc_string_end(bytes, i + 1);
            output.extend_from_slice(&bytes[i..end]);
            i = end;
            continue;
        }
        let trailing = bytes[i] == b','
            && bytes[i + 1..]
                .iter()
                .find(|b| !b.is_ascii_whitespace())
                .is_some_and(|b| *b == b'}' || *b == b']');
        if !trailing {
            output.push(bytes[i]);
        }
        i += 1;
    }
    serde_json::from_slice(&output).map_err(|e| format!("Invalid OpenCode config: {e}"))
}

fn configure(client: Client, text: &str, path: &Path) -> Result<String, String> {
    match client {
        Client::OpenCode => {
            let mut document = opencode_document(if text.trim().is_empty() { "{}" } else { text })?;
            let original = document.clone();
            crate::configure_opencode_mcp(&mut document, path)?;
            if original == document {
                return Ok(text.into());
            }
            serde_json::to_string_pretty(&document)
                .map(|s| s + "\n")
                .map_err(error_text)
        }
        Client::Codex => configure_codex(text),
    }
}

fn configure_codex(text: &str) -> Result<String, String> {
    let mut document = text
        .parse::<DocumentMut>()
        .map_err(|e| format!("Invalid Codex TOML: {}", e.message()))?;
    if !document.contains_key("mcp_servers") {
        document["mcp_servers"] = Item::Table(Table::new());
    }
    let servers = document["mcp_servers"]
        .as_table_like_mut()
        .ok_or("mcp_servers must be a TOML table")?;
    if !servers.contains_key("makevn") {
        servers.insert("makevn", value(InlineTable::new()));
    }
    let server = servers
        .get_mut("makevn")
        .and_then(Item::as_table_like_mut)
        .ok_or("mcp_servers.makevn must be a TOML table")?;
    // Preserve client permissions and unrelated options, removing incompatible transport fields.
    for key in ["url", "args"] {
        server.remove(key);
    }
    server.insert("command", value("makevn-mcp"));
    server.insert("enabled", value(true));
    server.insert("startup_timeout_sec", value(20));
    server.insert("tool_timeout_sec", value(1800));
    Ok(document.to_string())
}

fn config_status(client: Client, path: &Path) -> String {
    match read_config(client, path)
        .and_then(|text| configure(client, &text, path).map(|updated| (text, updated)))
    {
        Ok((original, updated)) if original == updated => "current".into(),
        Ok(_) => "absent or outdated; rerun agent install".into(),
        Err(error) => format!("invalid: {error}"),
    }
}

fn read_config(client: Client, path: &Path) -> Result<String, String> {
    agent_transaction::reject_links(path)?;
    let bytes = agent_transaction::read(path)?;
    String::from_utf8(bytes.unwrap_or_else(|| match client {
        Client::OpenCode => b"{}".to_vec(),
        Client::Codex => vec![],
    }))
    .map_err(error_text)
}

struct Lock(PathBuf);
impl Drop for Lock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn install(
    client: Client,
    config: &Path,
    source: &Path,
    target: &Path,
    version: &str,
) -> Result<(), String> {
    let (original, updated) = preflight(client, config, source, target, version)?;
    let _lock = acquire_lock(target)?;
    let mut changes = agent_skills::prepare(source, target, version)?;
    if read_config(client, config)? != original {
        return Err("Configuration changed during setup; retry".into());
    }
    changes.extend(configuration_changes(config, &original, &updated)?);
    agent_transaction::apply(changes)
}

fn preflight(
    client: Client,
    config: &Path,
    source: &Path,
    target: &Path,
    version: &str,
) -> Result<(String, String), String> {
    // Validate before creating a lock or any destination files.
    let _ = agent_skills::prepare(source, target, version)?;
    let original = read_config(client, config)?;
    let updated = configure(client, &original, config)?;
    Ok((original, updated))
}

fn acquire_lock(target: &Path) -> Result<Lock, String> {
    agent_transaction::reject_links(target)?;
    fs::create_dir_all(target).map_err(error_text)?;
    let lock = target.join(".makevn-setup.lock");
    OpenOptions::new().write(true).create_new(true).open(&lock)
        .map_err(|e| format!("Cannot acquire setup lock {}: {e}; check for an active setup before removing a stale lock", lock.display()))?;
    Ok(Lock(lock))
}

fn configuration_changes(
    config: &Path,
    original: &str,
    updated: &str,
) -> Result<agent_transaction::Changes, String> {
    let mut changes = agent_transaction::Changes::new();
    if updated == original {
        return Ok(changes);
    }
    if let Some(bytes) = agent_transaction::read(config)? {
        let backup = PathBuf::from(format!("{}.makevn.bak", config.display()));
        if !backup.exists() {
            changes.insert(backup, Some(bytes));
        }
    }
    changes.insert(config.to_path_buf(), Some(updated.as_bytes().to_vec()));
    Ok(changes)
}

#[cfg(test)]
#[path = "agent_setup_test.rs"]
mod tests;
