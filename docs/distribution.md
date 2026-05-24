# Distribution

## Current Goal

makevn should be easy for humans and AI agents to install without compiling from
source. Distribution is organized around three channels:

- Homebrew for macOS and Homebrew users
- asdf for WSL2, Linux, and managed developer workstations
- a release installer for fallback agent bootstrap

All channels should install the same runtime layout and the dedicated
`makevn-mcp` MCP server.

## GitHub Releases

The release workflow is manual through `workflow_dispatch`:

- `.github/workflows/release.yml`

Inputs:

- `version`, for example `v0.1.0-test.1`
- `target_ref`, usually `main`
- `prerelease`
- `draft`

What it does:

- checks out the requested ref
- creates a versioned source archive from the tagged revision
- generates a SHA-256 checksum file
- builds runtime archives for supported Linux and macOS targets
- creates a GitHub release with those assets attached

You can run it from the GitHub Actions UI or with `gh`:

```bash
gh workflow run release.yml -f version=v0.1.0-test.1 -f target_ref=main -f prerelease=true -f draft=false
```

## Homebrew

The tap `antonillos/homebrew-tap` has been created with the formula at
`Formula/makevn.rb`.

Install command:

```bash
brew install antonillos/tap/makevn
```

The formula lives in two places kept in sync:

- `antonillos/homebrew-tap/Formula/makevn.rb` (canonical)
- `antonillos/makevn/packaging/homebrew/makevn.rb` (reference copy)

The formula keeps both stable and `head` paths. Stable releases use the source
archive and a pinned SHA-256. The `head` path is for development builds.

The formula builds the Rust frontend from source and installs the runtime layout expected by `makevn`:

- `bin/makevn`
- `bin/makevn-mcp`
- `libexec/makevn/`
- `share/makevn/`
- `share/makevn/skills/makevn/`

The Rust build entrypoint exposed publicly by this repository is:

- `./build-rust-dispatcher.sh`

## asdf

The asdf plugin lives under `packaging/asdf/` in this repository and is intended
to be published as `antonillos/asdf-makevn`.

Install command:

```bash
asdf plugin add makevn https://github.com/antonillos/asdf-makevn.git
asdf install makevn latest
asdf global makevn latest
```

The plugin downloads a runtime archive from GitHub Releases, verifies its
SHA-256 checksum, and installs the archive layout directly.

## Fallback Installer

The fallback installer is for agents or ephemeral environments without Homebrew
or asdf:

```bash
curl -fsSL https://raw.githubusercontent.com/antonillos/makevn/main/packaging/install/install-release.sh | sh
```

It downloads a runtime archive from GitHub Releases, verifies its SHA-256
checksum, and installs into `~/.local` by default.

## MCP Server

The dedicated `makevn-mcp` binary runs the MCP server:

```bash
makevn-mcp
```

The server implements the Model Context Protocol over stdio JSON-RPC and
exposes each `makevn` subcommand as an MCP tool.

### Client configuration

```json
{
  "mcpServers": {
    "makevn": {
      "command": "makevn-mcp"
    }
  }
}
```

No npm or Node.js runtime is required. The MCP server is compiled from the Rust
dispatcher crate and installed alongside `makevn`.

## Agent Contract

Agents should use `docs/agent-install.md` for installation and MCP setup. The
stable MCP command is always `makevn-mcp`.
