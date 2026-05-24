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
asdf plugin add makevn https://github.com/antonillos/asdf-makevn.git || asdf plugin update makevn
asdf install makevn latest
asdf global makevn latest
```

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

## MCP Configuration

Use this command in MCP-compatible clients:

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

OpenCode can load repository MCP configuration from `.mcp.json` when
`makevn-mcp` is in `PATH`. After installing or upgrading makevn, restart or
reload the OpenCode session if the tool schema does not show makevn tools.

## Codex

Codex agents should use the CLI when MCP is not available:

```bash
makevn doctor
makevn verify-changes
```

When MCP support is available, configure the MCP command as `makevn-mcp` and
reload the session after install or upgrade.

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
