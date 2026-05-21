# Distribution

## Current Goal

Prepare three conventional distribution paths without opening the repository yet:

- a manual GitHub prerelease workflow
- a Homebrew formula ready to move into a dedicated tap later
- an MCP (Model Context Protocol) server for AI agent integration

## Manual GitHub Test Releases

This repository now includes a manual workflow:

- `.github/workflows/release-test.yml`

It is intentionally manual through `workflow_dispatch`.

Inputs:

- `version`, for example `v0.1.0-test.1`
- `target_ref`, usually `main`
- `prerelease`
- `draft`

What it does:

- checks out the requested ref
- creates a versioned source archive from the tagged revision
- generates a SHA-256 checksum file
- creates a GitHub release with those assets attached

You can run it from the GitHub Actions UI or with `gh`:

```bash
gh workflow run release-test.yml -f version=v0.1.0-test.1 -f target_ref=main -f prerelease=true -f draft=false
```

Current note while the repository remains private:

- the release is fine for internal testing
- release assets are not a public distribution channel yet

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

The formula is currently `head`-only on purpose because:

- there is no stable public release artifact to pin with `url` and `sha256` yet

When the first stable release is cut:

1. replace the `head` stanza with a stable `url` and `sha256` from a tagged release
2. update the `stable` block with the correct SHA-256
3. keep a `head` option for development builds

The formula builds the Rust frontend from source and installs the runtime layout expected by `makevn`:

- `bin/makevn`
- `bin/makevn-mcp`
- `libexec/makevn/`
- `share/makevn/`
- `share/makevn/skills/makevn/`

The Rust build entrypoint exposed publicly by this repository is:

- `./build-rust-dispatcher.sh`

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

## Private-Repo Caveat

As long as `antonillos/makevn` stays private, Homebrew and the published npm
package are only prepared technically.

That means:

- the formula is useful as a base
- the release workflow is useful for internal testing
- the normal public flow should wait until the repository and release assets are ready to be public
