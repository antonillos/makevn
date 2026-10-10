# Install

## Recommended Channels

Install makevn through one of these channels, in this order:

- Homebrew for macOS and users who already use Homebrew
- asdf for WSL2, Linux, and company-managed developer workstations
- the release installer as a fallback for agents or ephemeral environments

All release channels should install the same runtime layout: `makevn`,
`makevn-mcp`, `libexec/makevn/`, and `share/makevn/`.

## Requirements

Source install assumes:

- a POSIX shell environment
- `bash`
- standard Unix user-install paths such as `~/.local`
- Rust toolchain, including `cargo` (required for the default source build)

## Homebrew

```bash
brew install antonillos/tap/makevn
```

Upgrade with:

```bash
brew upgrade antonillos/tap/makevn
```

## asdf

```bash
asdf plugin add makevn https://github.com/antonillos/asdf-makevn.git
MAKEVN_VERSION="$(asdf latest makevn | sed -n '$p')"
asdf install makevn "${MAKEVN_VERSION}"
asdf set -u makevn "${MAKEVN_VERSION}"
asdf reshim makevn "${MAKEVN_VERSION}"
```

Upgrade with:

```bash
asdf plugin update makevn
MAKEVN_VERSION="$(asdf latest makevn | sed -n '$p')"
asdf install makevn "${MAKEVN_VERSION}"
asdf set -u makevn "${MAKEVN_VERSION}"
asdf reshim makevn "${MAKEVN_VERSION}"
```

## Agent Fallback Installer

Use this only when Homebrew or asdf are not available:

```bash
curl -fsSL https://raw.githubusercontent.com/antonillos/makevn/main/packaging/install/install-release.sh | sh
```

Install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/antonillos/makevn/main/packaging/install/install-release.sh | MAKEVN_VERSION=v0.1.0 sh
```

## Local Source Install

From the repository root:

```bash
./install.sh
```

`install.sh` compiles the current Rust `makevn` dispatcher and MCP server before
installing the complete runtime. A failed build leaves the existing installation
unchanged. Build timestamps describe compilation, not installation time.

Supported install modes:

- `./install.sh` builds current sources and installs them (requires Cargo)
- `./install.sh --rust` is a compatibility alias with the same default build
- `./install.sh --no-build` explicitly installs prebuilt artifacts without
  checking source freshness; intended for controlled packaging/test workflows
- `./install.sh --help` prints usage without building or installing

For an explicitly separated build/install workflow, avoid compiling twice:

```bash
./build-rust-dispatcher.sh
./install.sh --no-build
```

Update a source checkout with:

```bash
git pull && ./install.sh
```

Restart/reload MCP clients after installation; running sessions may retain the
previous server and tool descriptions. Release-channel installs do not require
local compilation; these Cargo requirements apply to source installation only.

By default this installs into `~/.local`:

- `~/.local/bin/makevn`
- `~/.local/bin/makevn-mcp`
- `~/.local/libexec/makevn/`
- `~/.local/share/makevn/`
- `~/.local/share/makevn/skills/makevn/`

If `~/.local/bin` is not in your `PATH`, add it first.

After installation, a quick sanity check is:

```bash
~/.local/bin/makevn --help
```

## Custom Prefix

```bash
PREFIX="$HOME/.local" ./install.sh --rust
```

For day-to-day Rust frontend development from a source checkout, the expected loop is:

```bash
./install.sh
~/.local/bin/makevn --repo "/path/to/java-repo" doctor
~/.local/bin/makevn --repo "/path/to/java-repo" compile
```

Target platform support:

- `macOS`
- `Linux`
- `Windows` through WSL2

The install contract should continue to ship the full runtime, not only the binary:

- `bin/`
- `libexec/`
- `share/`
- `skills/`

For the current target behavior and packaging assumptions, see:

- `docs/cli-contract.md`
- `docs/backend-contract.md`
