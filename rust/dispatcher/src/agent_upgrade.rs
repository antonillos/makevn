//! Synchronize the existing client integration with installed product resources.
use super::*;

pub fn run(scope: Option<Scope>) -> Result<(), String> {
    let paths = setup_paths()?;
    execute(
        scope,
        &paths.home,
        &paths.repo,
        &paths.config_home,
        &paths.codex_home,
        &paths.source,
    )
}

fn candidates(
    scope: Scope,
    repo: &Path,
    config_home: &Path,
    codex_home: &Path,
) -> Vec<(Client, PathBuf)> {
    let (opencode, codex) = match scope {
        Scope::Project => (local_configs(repo), repo.join(".codex/config.toml")),
        Scope::Global => (
            ["opencode.jsonc", "opencode.json"]
                .map(|name| config_home.join("opencode").join(name))
                .to_vec(),
            codex_home.join("config.toml"),
        ),
    };
    opencode
        .into_iter()
        .map(|path| (Client::OpenCode, path))
        .chain([(Client::Codex, codex)])
        .collect()
}

fn registered(client: Client, path: &Path) -> Result<bool, String> {
    let text = read_config(client, path)?;
    match client {
        Client::Codex => {
            let document = text
                .parse::<DocumentMut>()
                .map_err(|e| format!("Invalid Codex TOML: {}", e.message()))?;
            Ok(document
                .get("mcp_servers")
                .and_then(|servers| servers.get("makevn"))
                .is_some())
        }
        Client::OpenCode => {
            let document = opencode_document(&text)?;
            Ok(document.pointer("/mcp/makevn").is_some()
                || document.pointer("/mcp/servers/makevn").is_some())
        }
    }
}

fn integration(
    scope: Scope,
    home: &Path,
    repo: &Path,
    config_home: &Path,
    codex_home: &Path,
) -> Result<Option<Vec<(Client, PathBuf)>>, String> {
    let mut configs = Vec::new();
    for (client, path) in candidates(scope, repo, config_home, codex_home) {
        if registered(client, &path)? {
            configs.push((client, path));
        }
    }
    let manifest = skills_target(scope, home, repo).join(".makevn-skills.json");
    agent_transaction::reject_links(&manifest)?;
    Ok((manifest.exists() || !configs.is_empty()).then_some(configs))
}

fn execute(
    scope: Option<Scope>,
    home: &Path,
    repo: &Path,
    config_home: &Path,
    codex_home: &Path,
    source: &Path,
) -> Result<(), String> {
    let (scope, configs) = select(scope, home, repo, config_home, codex_home)?;
    let target = skills_target(scope, home, repo);
    upgrade(&configs, source, &target, crate::makevn_version())?;
    println!("Upgraded {:?} integration: {}\nRestart/reload registered clients to load updated MCP tools and skills.", scope, target.display());
    Ok(())
}

fn select(
    scope: Option<Scope>,
    home: &Path,
    repo: &Path,
    config_home: &Path,
    codex_home: &Path,
) -> Result<(Scope, Vec<(Client, PathBuf)>), String> {
    let scopes = scope
        .map(|scope| vec![scope])
        .unwrap_or_else(|| vec![Scope::Project, Scope::Global]);
    for selected in scopes {
        if selected == Scope::Project && crate::find_git_root(repo).is_none() {
            if scope.is_some() {
                return Err(format!(
                    "Project scope requires a Git worktree: {}",
                    repo.display()
                ));
            }
            continue;
        }
        if let Some(configs) = integration(selected, home, repo, config_home, codex_home)? {
            return Ok((selected, configs));
        }
    }
    Err("No existing MakeVN agent integration found; run makevn agent install <opencode|codex> first".into())
}

fn upgrade(
    configs: &[(Client, PathBuf)],
    source: &Path,
    target: &Path,
    version: &str,
) -> Result<(), String> {
    let _ = agent_skills::prepare(source, target, version)?;
    let prepared = prepare_configs(configs)?;
    let _lock = acquire_lock(target)?;
    let mut changes = agent_skills::prepare(source, target, version)?;
    for (client, path, original, updated) in prepared {
        if read_config(client, path)? != original {
            return Err("Configuration changed during setup; retry".into());
        }
        changes.extend(configuration_changes(path, &original, &updated)?);
    }
    agent_transaction::apply(changes)
}

fn prepare_configs(
    configs: &[(Client, PathBuf)],
) -> Result<Vec<(Client, &PathBuf, String, String)>, String> {
    configs
        .iter()
        .map(|(client, path)| {
            let original = read_config(*client, path)?;
            let updated = configure(*client, &original, path)?;
            Ok((*client, path, original, updated))
        })
        .collect()
}

#[cfg(test)]
#[path = "agent_upgrade_test.rs"]
mod tests;
