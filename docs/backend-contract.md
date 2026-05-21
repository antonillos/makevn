# Backend Contract

## Purpose

This document defines the internal contract between the future Rust frontend and the shell execution backend.

It exists to keep the implementation boundary small and explicit:

- Rust owns public CLI UX
- shell owns repository-aware execution
- neither side should need to scrape the other's human-oriented output

## Status

This is a target-state contract for the Rust transition.

Today, the Rust frontend already targets `libexec/makevn/backend.sh` as its single internal shell entrypoint. That backend is still transitional and currently adapts into `libexec/makevn/cli.sh` for the existing repository-aware execution logic while the boundary is being carved out.

Current implemented status:

- the Rust frontend no longer invokes `cli.sh` directly
- `backend.sh` already accepts normalized `BACKEND_COMMAND --repo ABS_PATH ...` invocations
- `doctor` and `compile` have been verified through the installed Rust frontend via `backend.sh`
- `backend.sh` is still a passthrough adapter into `cli.sh` for command execution
- `--metadata-out` is now implemented for Rust-owned interactive run-command dispatch
- `--format json` and explicit `--log-path` are not implemented yet in the transitional backend

## Responsibility Split

### Rust Frontend Owns

- public argument parsing
- public help and version output
- global option validation
- `--json` public output
- `--tail` UX
- interactive loader rendering for supported run commands
- interactive command header and explicit log-path notice rendering when backend metadata is available
- optional compact rolling mini-log rendering when `--tail` is active
- color policy for frontend output
- measuring command duration for NDJSON summaries
- translating user interruption into backend process interruption

### Shell Backend Owns

- repository-aware JDK resolution
- Maven executable resolution
- Maven, Docker, and configured run-command execution
- `.makevn/` state management
- `Makefile` and `.makevn/makevn.mk` generation or cleanup
- managed log-file creation for long-running commands
- preserving delegated exit codes when practical

## Internal Entrypoint

The Rust frontend should invoke a single internal shell entrypoint.

Target name used in this document:

```text
libexec/makevn/backend.sh
```

Notes:

- this is an internal interface, not a public user-facing command
- it may initially be implemented by adapting the current `cli.sh`
- future refactors may split backend logic into more files, but the frontend should still depend on one stable internal entrypoint

## Invocation Shape

The frontend should call the backend with normalized arguments, not by replaying the original raw user command line.

Base shape:

```bash
backend.sh BACKEND_COMMAND --repo ABS_PATH [BACKEND_OPTIONS...] [-- EXTRA_ARGS...]
```

Rules:

- `--repo` must always be an absolute path
- frontend-only flags such as `--tail` must not be forwarded
- backend commands should stay close to public command names where possible
- backend-specific flags are allowed when they simplify the boundary

## Backend Command Families

### State Commands

These commands return repository or environment state and do not rely on managed live log streaming.

State command family:

- `doctor`
- `init`
- `uninstall`
- `profile refresh`
- `jdk current`
- `jdk list`
- `docker-ps`
- `docker-stats`
- `docker-ps-required`

Recommended invocation pattern:

```bash
backend.sh doctor --repo /abs/repo --format json
backend.sh init --repo /abs/repo --mode standalone --dry-run --format json
backend.sh jdk current --repo /abs/repo --format json
```

Transitional note:

- today `backend.sh` only accepts `--format text` for the state-command family
- `--format json` is still part of the target contract, not the implemented behavior yet

### Run Commands

These commands execute work over time and should use managed logs instead of streaming human output from the backend.

Run command family:

- `compile`
- `test-compile`
- `compile-tests`
- `validate`
- `package`
- `build`
- `clean`
- `test`
- `verify-ut`
- `verify-ut-coverage`
- `verify-it`
- `verify-it-coverage`
- `verify`
- `verify-changes`
- `coverage`
- `coverage-changes`
- `pr-verify`
- `karate-test`
- `karate-all`
- `run-app`
- `run-app-bg`
- `stop-app`
- `exec`
- `run`
- `docker-up`
- `docker-down`

Recommended invocation pattern:

```bash
backend.sh build \
  --repo /abs/repo \
  --log-path /abs/repo/.makevn/logs/build.log \
  --metadata-out /tmp/makevn-build.meta \
  -- \
  -DskipTests
```

Transitional note:

- today run commands such as `compile` are already routed through `backend.sh`
- `--metadata-out` is available for the Rust frontend to discover header and log metadata without scraping shell output
- explicit `--log-path` is still pending target-state work
- current execution still relies on the existing managed-log behavior in `cli.sh` and `common.sh`
- changed-code verification and coverage analysis are self-contained in the installed backend; target repositories' legacy `scripts/make/*` trees are reference material only, not runtime dependencies

## Backend Output Modes

### State Commands

State commands should support:

- `--format text`
- `--format json`

Rules:

- `text` exists for direct debugging and transitional compatibility
- `json` exists so the Rust frontend never has to parse prose
- when `--format json` is used, `stdout` must contain only a single JSON document

### Run Commands

Run commands should not own public human UX.

Rules:

- managed child-process output goes to the managed log file, not to `stdout`
- backend `stdout` should remain empty during normal execution
- backend `stderr` should be reserved for early backend failures before the delegated process starts
- public NDJSON events should be emitted by Rust, not by the shell backend
- compact non-interactive summaries may print the log path, final status, duration, and a short failure excerpt, but not the full managed log stream

This keeps one source of truth for:

- agent-facing JSON
- human-facing summaries
- optional tail UX

## Metadata File Contract

Run commands should accept:

```text
--metadata-out ABS_PATH
```

Before launching the delegated long-running process, the backend should write a metadata file that the frontend can read without scraping terminal output.

### File Format

- UTF-8 text
- one `key=value` pair per line
- newline-delimited
- keys use lowercase ASCII with underscores
- values must be single-line
- the file must be fully written before the delegated process starts

Required fields:

- `command`
- `repo`
- `cwd`
- `log_path`
- `relative_log_path`
- `command_display`
- `context` when relevant

Currently implemented additive field:

- `title`

Definitions:

- `command`: logical command name such as `build`, `verify-changes`, or `coverage-changes`
- `repo`: absolute repository path
- `cwd`: working directory used for delegated execution
- `log_path`: absolute log path
- `relative_log_path`: repo-relative log path, typically under `.makevn/logs/`
- `command_display`: single-line shell-quoted display form of the delegated command
- `context`: execution context such as `code` or `karate` when applicable

Example:

```text
command=build
repo=/work/repo
cwd=/work/repo
log_path=/work/repo/.makevn/logs/build.log
relative_log_path=.makevn/logs/build.log
command_display=./mvnw -f /work/repo/pom.xml package -DskipTests
title=build
context=code
```

Optional additive fields are allowed later.

## Log Ownership

Managed logs are a backend responsibility.

Rules:

- for run commands with managed logging, the frontend chooses the absolute log path and passes it explicitly with `--log-path`
- the backend may create parent directories when needed
- the backend writes combined delegated `stdout` and `stderr` to the log file
- the backend should truncate and recreate the log file for each run unless a future append mode is explicitly introduced
- the backend should not require the frontend to parse live terminal output to discover log paths
- backend-owned log prologue or epilogue lines should stay compact so frontend mini-log views do not waste most of their small window on bookkeeping

Implications:

- `--tail` can be implemented entirely in Rust by following `log_path`
- log file naming remains stable and inspectable
- backend execution remains useful even when no frontend tailing is active

## Exit Codes

The backend should preserve this small contract:

- `0`: success
- `1`: backend validation error, setup error, or generic failure without a more specific delegated exit code
- `130`: interruption or cancellation
- any other non-zero code: preserved delegated exit code when practical

Rules:

- invalid backend invocations should return `1`
- delegated Maven, Docker, or configured command exit codes should be preserved when practical
- if the delegated process is interrupted, backend should exit `130`

## Signals And Cancellation

Rust should treat the backend process as the cancellation boundary.

Rules:

- frontend sends interruption to the backend process
- backend is responsible for forwarding interruption to delegated child processes when needed
- backend should avoid leaving orphaned child processes in normal interruption paths
- backend should convert successful interruption handling into exit code `130`

The frontend should not need child-process-tree knowledge beyond the backend PID.

## Environment Contract

The backend may rely on the normal inherited user environment, including:

- `PATH`
- `HOME`
- `JAVA_HOME`
- `NO_COLOR`
- repository-specific environment variables already used by current scripts

The frontend may additionally set internal markers such as:

- `MAKEVN_FRONTEND=rust`
- `MAKEVN_FRONTEND_VERSION=<version>`

Rules:

- the backend must not require frontend-private environment variables for core correctness if an equivalent explicit flag exists
- log path and metadata path should be passed as explicit flags, not hidden environment variables
- agent-safe workflows must be reachable through public commands and installed backend runtime files; target-repository helper scripts are not part of the backend contract

## Option Forwarding Rules

The frontend is responsible for public CLI validation first.

Implications:

- unsupported public flag combinations should be rejected before the backend is invoked
- `--json` and `--tail` are frontend concepts and should not be forwarded as public flags
- extra delegated Maven arguments remain the only arguments forwarded after `--` for Maven-oriented commands

Examples:

- `makevn build --tail -- -DskipTests` becomes a backend `build` invocation with explicit `--log-path`, plus `-DskipTests` after `--`
- `makevn doctor --json` becomes a backend `doctor --format json`

## Compatibility Rules

The frontend may evolve without breaking the backend contract if it preserves:

- one stable internal entrypoint
- `--repo ABS_PATH`
- `--format json|text` for state commands
- `--log-path ABS_PATH` for managed-log run commands
- `--metadata-out ABS_PATH` for managed-log run commands
- exit-code semantics

The backend may evolve additively by:

- adding JSON fields on state commands
- adding optional metadata keys
- adding support for managed logs to more run commands

For both humans and AI agents, compatibility means the same invocation should work
from an interactive terminal, a local automation, or an agent tool runner. Human-only
features such as `--tail` must remain optional, while commands such as
`verify-changes` and `coverage-changes` must remain usable in non-interactive runs
without relying on IDE state or repository-local legacy scripts.

## Non-Goals

This contract does not require:

- the backend to emit public NDJSON directly
- the backend to implement user-facing color or spinner behavior
- the frontend to parse human-oriented backend output
- native `Windows` support outside WSL
