# makevn

Terminal-first workflows for Java Maven repositories.

`makevn` is a CLI for teams and AI agents that want to run Java Maven workflows from the terminal with the correct local Java context, without depending on IDE-specific setup.

The current public foundation is shell-first. The next major transition is a Rust frontend that preserves the same command surface while keeping shell as the execution backend.

## Why

If a repository is already Java + Maven, the core local workflow already exists.

The build, test, verify, and packaging model is already described by:

- `pom.xml`
- module structure
- Maven plugins and conventions
- local toolchain signals such as `.tool-versions`

The problem is usually not missing capability. The problem is that execution often gets hidden behind IDE configuration, shell state, or local tribal knowledge.

`makevn` makes that execution contract explicit.

## Scope

This project is intentionally narrow:

- Java repositories
- Maven builds
- local JDK resolution
- terminal-first execution
- optional `make` integration
- agent-friendly command surface

Planned product direction:

- Rust frontend for CLI UX, help, `--json`, and optional `--tail`
- shell backend for repository-aware execution and log creation
- Homebrew and curl-install distribution as first-class install paths

This repository is not trying to go beyond Java + Maven.

## Key Guarantee

`makevn` does not overwrite an existing root `Makefile` or `GNUmakefile`.

It supports three explicit modes:

- `standalone`
- `make-include`
- `make-bootstrap`

## Quick Start

From this repository:

```bash
./scripts/build-rust-dispatcher.sh
./install.sh --rust
~/.local/bin/makevn --help
```

If you want to install the current shell entrypoint explicitly:

```bash
./install.sh --shell
```

Current install status:

- source install through `./install.sh` works today
- `./install.sh` installs the Rust frontend when `target/release/makevn` already exists, otherwise it falls back to the shell entrypoint
- `./install.sh` does not compile Rust; build the dispatcher first if you want the Rust frontend
- `./install.sh --rust` fails fast when the Rust dispatcher has not been built yet
- `./install.sh --shell` forces the current shell entrypoint explicitly
- Homebrew and curl-install are planned distribution channels, but are not the current release path yet

In a target repository:

```bash
makevn doctor
makevn init --mode standalone
makevn test --name UserRepositoryTest
makevn verify
makevn --tail clean verify-it
```

From another repository, you can also target a repo explicitly:

```bash
~/.local/bin/makevn --repo "/path/to/java-repo" doctor
~/.local/bin/makevn --repo "/path/to/java-repo" compile
```

If the target repository already has a `Makefile` and you want optional `make` usage without collisions:

```bash
makevn init --mode make-include
make -f .makevn/makevn.mk vn-doctor
```

If the target repository has no `Makefile` and you explicitly want one:

```bash
makevn init --mode make-bootstrap
make -f .makevn/makevn.mk vn-build
```

## Commands

```bash
makevn --tail clean verify-it
makevn clean verify-it --tail
makevn doctor
makevn init --mode standalone
makevn init --mode make-include
makevn init --mode make-bootstrap
makevn uninstall
makevn compile
makevn compile-tests
makevn validate
makevn package
makevn build
makevn test
makevn test --name UserRepositoryTest
makevn test --name UserRepositoryTest,OrderRepositoryTest
makevn test --fast --name UserRepositoryTest
makevn verify-ut
makevn verify-ut-coverage
makevn verify-it
makevn verify-it-coverage
makevn verify
makevn verify-changes
makevn pr-verify
makevn docker-up
makevn docker-down
makevn docker-ps
makevn run
makevn exec -- mvn -v
makevn jdk current
makevn jdk list
```

Planned global UX additions during the Rust transition:

- `--json` on every public command
- `--tail` on managed long-running commands only, usable as a global option before or after a command chain
- `--no-color` for explicit frontend color control

Selected-test notes:

- `makevn test` runs the full suite
- `makevn test --name FooTest` runs one selected test
- `makevn test --name FooTest,BarTest` or repeated `--name` flags run selected tests sequentially
- `makevn test --fast --name FooTest` uses the cached fast path for selected tests

Command-chain notes:

- the preferred public shape is `makevn [global_options] command [options] command [options] ...`
- `--repo` and `--tail` can be used as global options before the command chain
- `--tail` is also accepted at the end of the chain as compatibility sugar
- commands in a chain run sequentially and stop at the first non-zero exit code
- command-local options apply only to the command they follow
- when `--tail` is enabled, the final output remains compact and collapses to `:: log: ...` plus `[ok] <duration>` per command

Example:

```text
~/.local/bin/makevn --repo . --tail clean verify-it
:: makevn clean
:: log: .makevn/logs/clean.log
[ok] 4s
:: makevn verify-it
:: log: .makevn/logs/verify-it.log
[ok] 1m 16s
```

## Make Integration

The shared include uses namespaced targets only:

- `vn-doctor`
- `vn-compile`
- `vn-compile-tests`
- `vn-validate`
- `vn-package`
- `vn-build`
- `vn-clean`
- `vn-test`
- `vn-verify-ut`
- `vn-verify-ut-coverage`
- `vn-verify-it`
- `vn-verify-it-coverage`
- `vn-verify`
- `vn-verify-changes`
- `vn-pr-verify`
- `vn-docker-up`
- `vn-docker-down`
- `vn-docker-ps`
- `vn-run`
- `vn-jdk-current`
- `vn-jdk-list`

That is how `makevn` avoids colliding with repo-owned targets such as `build`, `test`, or `run`.

Examples:

```bash
make -f .makevn/makevn.mk vn-test NAME=UserRepositoryTest
make -f .makevn/makevn.mk vn-test NAMES="UserRepositoryTest,OrderRepositoryTest"
make -f .makevn/makevn.mk vn-test NAME=UserRepositoryTest FAST=true
```

## AI Agent Skill

This repository ships a reusable agent skill under `skills/makevn/`.

The skill teaches agents to:

- run `makevn doctor` before `makevn init`
- preserve existing `Makefile` compatibility
- choose the least invasive mode
- use `makevn uninstall` for rollback
- operate the repository through terminal commands that also work from OpenCode
- treat the installed `makevn` binary as the primary interface
- prefer `--json` when structured output becomes publicly available
- avoid `--tail` unless a human explicitly asks for an interactive local view

## Repository Layout

```text
.
├── README.md
├── bin/
├── docs/
├── libexec/
├── rust/
├── scripts/
├── test/
├── share/
└── skills/
```

Notes:

- `GNUmakefile`, `GNUmakefile.md`, `PLAN.md`, and `ROADMAP.md` are local development/reference material and are not part of the published repository surface.
- the public runtime exposed by this repository is `bin/`, `libexec/`, `share/`, and `skills/`.
- `rust/dispatcher/` contains the transitional Rust frontend crate.
- the public interface is now the `makevn` CLI plus the optional `.makevn/makevn.mk` integration file.

## Documentation

- `docs/install.md`
- `docs/rust-transition-status.md`
- `docs/integration.md`
- `docs/agents.md`
- `docs/cli-contract.md`
- `docs/backend-contract.md`
- `docs/philosophy.md`
- `docs/github-about.md`

## Status

Early public foundation.

The CLI, repo-local integration model, skill package, and smoke tests already exist.

The current public CLI already covers:

- compile/build/package/validate flows
- full-suite and selected-test execution
- split verification flows for UT, IT, coverage, changed-code verification, and PR-style verification
- namespaced `make` integration for the same workflows

Current public limitations to keep in mind:

- public `--json` output is planned but not available yet
- repository-aware execution still runs through the shell backend even when invoked from the Rust frontend
- Homebrew and curl-install are planned distribution channels, not current release channels

The next major phase is the Rust CLI transition:

- preserve the public command surface
- move public CLI UX ownership into Rust
- keep shell as the execution backend
- define `--json` across the command surface
- add optional managed-log tailing for human use

Current transition status:

- the Rust dispatcher binary exists and can be built from `rust/dispatcher/`
- `install.sh` is now install-only and can require a prebuilt Rust frontend with `--rust`
- `libexec/makevn/backend.sh` now exists as the single internal shell entrypoint used by the Rust frontend
- `--version`, global `--help`, command validation, repo normalization, the `help` command, and `compile` dispatch can now move into the Rust frontend without changing the backend execution path
- `doctor` and `compile` have been verified through the installed Rust binary using the new backend entrypoint
- the shell backend remains the execution path for repository-aware commands

After that boundary is in place, the remaining parity work around formatting, mutation, and broader coverage/reporting can continue on a more stable interface.
