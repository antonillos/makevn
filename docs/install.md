# Install

## Direction

The installation strategy is moving toward two first-class distribution paths:

- Homebrew
- a curl-install path for local user installs

Those release channels are planned, but the current repository install path is still source-first.

## Requirements

Current source install assumes:

- a POSIX shell environment
- `bash`
- standard Unix user-install paths such as `~/.local`
- Rust only when you want the Rust frontend from source

## Local Source Install

From the repository root:

```bash
./build-rust-dispatcher.sh
./install.sh --rust
```

If you want the current shell entrypoint instead of the Rust frontend:

```bash
./install.sh --shell
```

`install.sh` does not compile Rust. It installs the Rust `makevn` dispatcher only when a
prebuilt `target/release/makevn` already exists. Otherwise it falls back to the current
shell entrypoint.

Use `--rust` when you want installation to fail fast unless the Rust frontend is already
built. Use `--shell` to force the shell entrypoint explicitly.

Supported install modes today:

- `./install.sh` installs the Rust frontend when `target/release/makevn` already exists, otherwise falls back to the shell entrypoint
- `./install.sh --rust` requires a prebuilt Rust dispatcher and fails if it is missing
- `./install.sh --shell` always installs the current shell entrypoint
- `./install.sh --help` prints the installer usage

By default this installs into `~/.local`:

- `~/.local/bin/makevn`
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

The installer is intentionally simple for now. External packaging such as Homebrew or release artifacts can be added later without changing the repo-local integration model.

If you only want to exercise the shell implementation from a source checkout, `./install.sh --shell` is the most direct path.

## Planned Distribution Channels

Target channels:

- Homebrew for `macOS` and Linux users who want standard package-manager installation
- curl-install for humans and AI agents that need a one-line local install without root

Target platform support:

- `macOS`
- `Linux`
- `Windows` through WSL

The install contract should continue to ship the full runtime, not only the binary:

- `bin/`
- `libexec/`
- `share/`
- `skills/`

For the current target behavior and packaging assumptions, see:

- `docs/cli-contract.md`
- `docs/backend-contract.md`
