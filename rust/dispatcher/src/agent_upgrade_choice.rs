//! Interactive selection keeps linked configuration writes explicit.
use super::*;

struct Config {
    client: Client,
    path: PathBuf,
    destination: PathBuf,
}

impl Config {
    fn linked(&self) -> bool {
        self.path != self.destination
    }
}

struct Choice {
    scope: Scope,
    configs: Vec<Config>,
}

pub(super) fn select(
    scope: Option<Scope>,
    paths: &SetupPaths,
    input: &mut impl io::BufRead,
    output: &mut impl Write,
) -> Result<(Scope, Vec<(Client, PathBuf)>), String> {
    let choices = discover(scope, paths)?;
    let selected = choose(&choices, input, output)?;
    let choice = &choices[selected];
    let mut configs = Vec::new();
    for config in &choice.configs {
        validate(config)?;
        let entry = (config.client, config.destination.clone());
        if !configs.contains(&entry) {
            configs.push(entry);
        }
    }
    Ok((choice.scope, configs))
}

fn validate(config: &Config) -> Result<(), String> {
    if config.linked() && fs::canonicalize(&config.path).map_err(error_text)? != config.destination
    {
        return Err("Configuration link changed during selection; retry".into());
    }
    agent_transaction::reject_links(&config.destination)
}

fn discover(scope: Option<Scope>, paths: &SetupPaths) -> Result<Vec<Choice>, String> {
    let scopes = scope
        .map(|scope| vec![scope])
        .unwrap_or_else(|| vec![Scope::Project, Scope::Global]);
    let mut choices = Vec::new();
    for selected in scopes {
        if selected == Scope::Project && crate::find_git_root(&paths.repo).is_none() {
            if scope.is_some() {
                return Err("Project scope requires a Git worktree".into());
            }
            continue;
        }
        append_choices(selected, paths, &mut choices)?;
    }
    if choices.is_empty() {
        return Err("No existing MakeVN agent integration found; run makevn agent install <opencode|codex> first".into());
    }
    Ok(choices)
}

fn configuration_destination(path: &Path) -> Result<PathBuf, String> {
    match agent_transaction::reject_links(path) {
        Ok(()) => Ok(path.to_path_buf()),
        Err(_) => fs::canonicalize(path)
            .map_err(|e| format!("Cannot resolve configuration {}: {e}", path.display())),
    }
}

fn discover_configs(scope: Scope, paths: &SetupPaths) -> Result<Vec<Config>, String> {
    let mut configs = Vec::new();
    for (client, path) in candidates(scope, &paths.repo, &paths.config_home, &paths.codex_home) {
        let destination = configuration_destination(&path)?;
        if registered(client, &destination)? {
            configs.push(Config {
                client,
                path,
                destination,
            });
        }
    }
    Ok(configs)
}

fn append_choices(
    scope: Scope,
    paths: &SetupPaths,
    choices: &mut Vec<Choice>,
) -> Result<(), String> {
    let configs = discover_configs(scope, paths)?;
    let manifest = skills_target(scope, &paths.home, &paths.repo).join(".makevn-skills.json");
    agent_transaction::reject_links(&manifest)?;
    if configs.is_empty() && !manifest.exists() {
        return Ok(());
    }
    if configs.len() > 1 {
        for config in &configs {
            choices.push(Choice {
                scope,
                configs: vec![Config {
                    client: config.client,
                    path: config.path.clone(),
                    destination: config.destination.clone(),
                }],
            });
        }
    }
    choices.push(Choice { scope, configs });
    Ok(())
}

fn choose(
    choices: &[Choice],
    input: &mut impl io::BufRead,
    output: &mut impl Write,
) -> Result<usize, String> {
    if choices.len() == 1 && !choices[0].configs.iter().any(Config::linked) {
        return Ok(0);
    }
    write_menu(choices, output)?;
    read_selection(choices.len(), input, output)
}

fn write_menu(choices: &[Choice], output: &mut impl Write) -> Result<(), String> {
    writeln!(
        output,
        "Which integration should MakeVN upgrade? (0 cancels)"
    )
    .map_err(error_text)?;
    for (index, choice) in choices.iter().enumerate() {
        write_choice(index, choice, output)?;
    }
    Ok(())
}

fn write_choice(index: usize, choice: &Choice, output: &mut impl Write) -> Result<(), String> {
    writeln!(
        output,
        "  {}) {:?} integration ({} configuration(s))",
        index + 1,
        choice.scope,
        choice.configs.len()
    )
    .map_err(error_text)?;
    for config in &choice.configs {
        write_config(config, output)?;
    }
    if choice.configs.is_empty() {
        writeln!(output, "     Managed skills only").map_err(error_text)?;
    }
    Ok(())
}

fn write_config(config: &Config, output: &mut impl Write) -> Result<(), String> {
    write!(
        output,
        "     {:?}: {}",
        config.client,
        config.path.display()
    )
    .map_err(error_text)?;
    if config.linked() {
        write!(
            output,
            " -> {} (update destination, preserve link)",
            config.destination.display()
        )
        .map_err(error_text)?;
    }
    writeln!(output).map_err(error_text)
}

fn read_selection(
    count: usize,
    input: &mut impl io::BufRead,
    output: &mut impl Write,
) -> Result<usize, String> {
    write!(output, "Select an option: ").map_err(error_text)?;
    output.flush().map_err(error_text)?;
    let mut answer = String::new();
    input.read_line(&mut answer).map_err(error_text)?;
    let selected = answer
        .trim()
        .parse::<usize>()
        .ok()
        .and_then(|n| n.checked_sub(1))
        .filter(|n| *n < count)
        .ok_or("No integration selected; nothing was changed")?;
    Ok(selected)
}

#[cfg(test)]
#[path = "agent_upgrade_choice_test.rs"]
mod tests;
