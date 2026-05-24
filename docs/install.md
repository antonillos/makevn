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
- Rust

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
asdf install makevn latest
asdf global makevn latest
```

Upgrade with:

```bash
asdf plugin update makevn
asdf install makevn latest
asdf global makevn latest
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
./build-rust-dispatcher.sh
./install.sh --rust
```

`install.sh` does not compile Rust. It installs the Rust `makevn` dispatcher and
`makevn-mcp` only when prebuilt binaries already exist under `target/release/`.

Supported install modes today:

- `./install.sh` requires prebuilt Rust binaries and fails if they are missing
- `./install.sh --rust` is accepted for compatibility and has the same behavior
- `./install.sh --help` prints the installer usage

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
./build-rust-dispatcher.sh
./install.sh --rust
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
