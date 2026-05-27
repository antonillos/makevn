# Contributing

Thanks for your interest in contributing to makevn.

makevn provides a stable terminal-first command surface for Java Maven repositories. Changes should keep the tool predictable for both humans and AI agents.

## Before You Start

- Check existing issues and pull requests to avoid duplicate work.
- Open an issue first for large behavior changes, new commands, or changes that affect installation and release flows.
- Keep changes focused and avoid unrelated cleanup in the same pull request.

## Development Setup

For local development from this repository:

```bash
./build-rust-dispatcher.sh
./install.sh --rust
~/.local/bin/makevn --help
```

The Rust dispatcher lives under `rust/dispatcher`. Shell command behavior lives under `libexec/makevn/`.

## Testing

Run the smallest relevant check for your change before opening a pull request.

Useful commands include:

```bash
./build-rust-dispatcher.sh
cargo test --manifest-path rust/dispatcher/Cargo.toml
test/sanitize/run.sh
test/repo-sweep/run.sh
```

For changes affecting release packaging, also review the scripts under `packaging/release/` and the release workflows under `.github/workflows/`.

## Pull Requests

- Describe what changed and why.
- Include verification steps and results.
- Update documentation when user-facing behavior changes.
- Keep compatibility in mind for existing installed versions and package managers.
- Do not include secrets, local machine paths, or generated build artifacts unless explicitly required.

## Code Style

- Use English for code, comments, and documentation.
- Prefer small, direct changes over broad refactors.
- Keep shell scripts portable and defensive.
- Preserve existing command names, output contracts, and non-interactive behavior unless the change intentionally updates them.

## Security

Do not report suspected vulnerabilities in public issues. Follow the instructions in [SECURITY.md](SECURITY.md).
