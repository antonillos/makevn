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
      "timeout": 900000
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

Codex configuration file:

- Global TOML: `~/.codex/config.toml`
- Project TOML: `.codex/config.toml` in trusted projects only

Add this TOML table:

```toml
[mcp_servers.makevn]
command = "makevn-mcp"
enabled = true
startup_timeout_sec = 20
tool_timeout_sec = 900
```

Alternatively, add it with the Codex CLI:

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
