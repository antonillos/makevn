# Agent Install And MCP Setup

This page is the installation runbook for AI agents that need to install,
upgrade, or configure makevn before working in a Java/Maven repository.

## Install Priority

Use the first available channel:

1. Homebrew, when `brew` is available.
2. asdf, when `asdf` is available.
3. The release installer, only as a fallback.

Do not build from source unless the human is developing makevn itself.

## Homebrew

Install or upgrade:

```bash
if command -v makevn >/dev/null 2>&1; then
  brew upgrade antonillos/tap/makevn
else
  brew install antonillos/tap/makevn
fi
```

## asdf

Install or upgrade:

```bash
if asdf plugin list | grep -qx makevn; then
  asdf plugin update makevn
else
  asdf plugin add makevn https://github.com/antonillos/asdf-makevn.git
fi

MAKEVN_VERSION="$(asdf latest makevn | sed -n '$p')"
asdf install makevn "${MAKEVN_VERSION}"
asdf set -u makevn "${MAKEVN_VERSION}"
asdf reshim makevn "${MAKEVN_VERSION}"
```

`asdf` 0.16+ uses `asdf set -u` instead of the legacy `asdf global` command.

## Fallback Installer

Use this only when Homebrew and asdf are not available:

```bash
curl -fsSL https://raw.githubusercontent.com/antonillos/makevn/main/packaging/install/install-release.sh | sh
```

Install a pinned version:

```bash
curl -fsSL https://raw.githubusercontent.com/antonillos/makevn/main/packaging/install/install-release.sh | MAKEVN_VERSION=v0.1.0 sh
```

The fallback installer defaults to `~/.local`. Agents should ensure
`~/.local/bin` is in `PATH` before starting or reloading an MCP client.

## Verify Installation

```bash
makevn --version
command -v makevn-mcp
```

`makevn-mcp` is the MCP server command. Do not configure MCP clients to run
`makevn --mcp`.

## Generic MCP Configuration

Use `makevn-mcp` as the MCP server command. Do not use `makevn --mcp`.

Clients that use the common `mcpServers` JSON shape should use:

```json
{
  "mcpServers": {
    "makevn": {
      "command": "makevn-mcp"
    }
  }
}
```

If the client requires an absolute path, resolve it with:

```bash
command -v makevn-mcp
```

## OpenCode

Register MCP and all five skills:

```bash
makevn agent install opencode --scope global
makevn agent status opencode --scope global
```

When the current Git repository contains OpenCode configurations under
`.opencode/`, the interactive command lists every detected local JSON or JSONC
file separately, followed by the global configuration. The first local JSONC
file is the default choice. The command is idempotent, preserves other
configuration entries, and creates a backup before changing an existing
configuration. Restart OpenCode after installation.

OpenCode configuration files:

- Global JSON: `~/.config/opencode/opencode.json`
- Global JSONC: `~/.config/opencode/opencode.jsonc`
- Project JSON: `./opencode.json` or `.opencode/opencode.json`
- Project JSONC: `./opencode.jsonc`

Add this under the top-level `"mcp"` key:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "makevn": {
      "type": "local",
      "command": ["makevn-mcp"],
      "enabled": true,
      "timeout": 1800000
    }
  }
}
```

If the config file already has `"mcp"`, add only the `"makevn"` entry inside
that object. OpenCode requires `command` to be an array, not a string.

This repository also ships `.mcp.json` for clients that read that format. Use
the global OpenCode config above when the agent must have makevn tools in every
repository.

Restart OpenCode after changing config or installing makevn. OpenCode does not
hot-reload MCP configuration.

## Codex

```bash
makevn agent install codex --scope global
makevn agent status codex --scope global
```

Use `--scope project` for `.codex/config.toml` and `.agents/skills/` in the
current Git worktree. Codex loads project configuration only for trusted projects;
setup does not change trust or permission settings. Global config honors `CODEX_HOME`.


Codex configuration file:

- Global TOML: `~/.codex/config.toml`
- Project TOML: `.codex/config.toml` in trusted projects only

Add this TOML table:

```toml
[mcp_servers.makevn]
command = "makevn-mcp"
enabled = true
startup_timeout_sec = 20
tool_timeout_sec = 1800
```

This client timeout applies to the entire tool call, including all workflow
steps. Existing clients must load this value from their active configuration.
Both agent setup commands write this timeout. Use a larger value for workflows exceeding 30 minutes.

For MCP-only manual configuration (does not register skills):

```bash
codex mcp add makevn -- makevn-mcp
```

Use `/mcp` in the Codex TUI to confirm that the `makevn` server is active.

Codex agents should use the CLI when MCP is not active:

```bash
makevn doctor
makevn verify-changes
```

Reload the Codex session after installing or upgrading makevn so Codex reads the
current MCP tool schema.

## Claude Code

Configure the MCP server command as `makevn-mcp`. If the client caches tool
schemas, restart the Claude Code session after installing or upgrading makevn.

## First Repository Command

After installation and MCP reload, the first command in a target Java/Maven
repository should be:

```bash
makevn doctor
```

When using MCP tools directly, call the `makevn_doctor` tool first.

## Skill registration contract

`makevn agent install <opencode|codex> [--scope global|project]` registers MCP and
`makevn`, `makevn-test`, `makevn-docker`, `makevn-karate`, `makevn-quality` together.
Product installation distributes resources but does not edit client configuration.
Run `makevn agent upgrade` after a product upgrade. `makevn uninstall` removes repository
integration only; it does not unregister skills or uninstall the product.

Global skills are shared by both clients under `~/.agents/skills/`; project skills
are under `.agents/skills/` at the Git worktree root. Both scopes contain complete
copies, including references. OpenCode global config honors `XDG_CONFIG_HOME`.
Explicit project setup selects the first existing local config in this order:
`.opencode/opencode.jsonc`, `.opencode/opencode.json`, `.opencode/config.jsonc`,
`.opencode/config.json`, `opencode.jsonc`, `opencode.json`; otherwise it creates
`.opencode/opencode.json`. Without scope, interactive OpenCode setup offers each
existing config and then global scope; noninteractive setup uses global scope.
Codex defaults to global scope. Status requires an explicit scope and never prompts.

The `.makevn-skills.json` ownership manifest records version and SHA-256 file hashes.
Only unchanged managed resources can be updated or removed. Foreign names, local
edits, missing managed files, extra resources and symlinks block replacement with
paths and reasons. Inspect and preserve custom content before retrying; setup does
not override skill permissions. Repeating setup is idempotent. Skill registration
is shared across clients: registering the second client reuses the same managed
bundle and configures that client's MCP entry separately.

Preflight validates resources and configuration before changes. Setup serializes
writers with `.makevn-setup.lock`, stages files, backs up existing configuration
as `<config>.makevn.bak` if no backup exists, and restores replaced files after an
operation failure. Existing backups are preserved. A process crash can leave the
lock behind; verify no setup is active before removing a stale lock. This is not
a power-loss recovery mechanism. OpenCode JSONC comments may be normalized when
configuration changes; unrelated configuration values are retained. Existing OpenCode V2 `mcp.servers` layout is
preserved with native `disabled` and per-phase timeout fields; legacy MCP layouts
remain compatible. Codex TOML
comments and unrelated tables are retained.

```bash
makevn agent status opencode --scope global
makevn agent status codex --scope project
```

Status prints distributed-resource and destination paths, skill registration
(absent/current/outdated/conflict), and MCP configuration status. A completed
status command is a diagnostic, not proof of healthy configuration or client loading.
After setup restart/reload the client, inspect its skills catalog and explicitly
load all five skills. Then evaluate representative workflow requests using the
[client validation checklist](agent-skills-validation.md). A model can choose not
to load an available skill; installation cannot guarantee implicit selection.

## Upgrade existing agent integration

After upgrading MakeVN through its installation channel, synchronize the existing
agent integration with the resources shipped in the installed version:

```bash
makevn agent upgrade
```

The current Git worktree takes precedence when it contains a managed skill
manifest or a registered MakeVN MCP entry. Otherwise, upgrade falls back to the
global integration. Repository initialization alone (`.makevn/`) does not establish
a project agent registration. Running from a repository subdirectory still uses
the worktree root. No Maven project or doctor initialization is required.

Upgrade refreshes the shared skills and references and all registered Codex and
OpenCode MCP configurations in the selected scope. It does not register clients
that have no MakeVN entry. A skills-only registration is also supported. If no
integration exists, run `makevn agent install <opencode|codex>` first.

Use `makevn agent upgrade --scope global` or `--scope project` to override scope
detection. Explicit project scope requires a Git worktree. Upgrade preserves
unrelated configuration and uses the same ownership checks, backups, locking and
rollback as installation. Local skill edits block replacement; a project conflict
does not silently fall back to global scope. All selected configurations are
validated before resources are replaced.

This command updates agent integration from the installed distribution; it does
not download a release or update the MakeVN executable. Restart/reload registered
clients afterward to discover the updated MCP schema and skills.
