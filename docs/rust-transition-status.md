# Rust Transition Status

## Purpose

This document is the handoff point for the current Rust frontend transition.

If a new session needs to continue the migration work, start here first.

## Current State

`makevn` is now split across:

- a transitional Rust frontend in `rust/dispatcher/`
- a stable internal shell entrypoint at `libexec/makevn/backend.sh`
- the existing shell implementation in `libexec/makevn/cli.sh` and `libexec/makevn/common.sh`

Today, the Rust frontend no longer invokes `cli.sh` directly. It invokes `backend.sh`, and `backend.sh` currently adapts into `cli.sh` while the backend boundary is being carved out.

Latest verified transition work:

- the Rust frontend loader was tuned to render at about 10 fps so the full KITT-style animation, including glow/trail frames, is visible in the terminal
- `doctor` remains backend-owned scripting, but `backend.sh doctor --format json` is now implemented as the internal transport shape for frontend consumption
- the Rust frontend now keeps tailed command output compact and settles each successful command as `:: log: ...` plus `[ok] <duration>`
- successful interactive run commands now end with a compact frontend summary in the form `[ok] <duration>`, and the backend log footer is written as a single compact line
- when `--tail` is enabled, the rolling mini-log now clears on completion and collapses back to a compact `:: log: ...` line before the final summary
- the spinner line can now show a lightweight CPU and RAM indicator for the backend process tree while the command is running, followed by the current interrupt hint
- command chaining is now implemented in the Rust frontend with the public shape `makevn [global_options] command [options] command [options] ...`, and `--tail` can be global at the front or accepted as compatibility sugar at the end

## Implemented Frontend-Owned Behavior

The Rust frontend currently owns:

- `--version`
- global `--help`
- `help`
- public command validation for the known command surface
- command-chain parsing and sequential dispatch for supported commands
- repo-path normalization before backend invocation
- normalized dispatch into `libexec/makevn/backend.sh`
- interactive loader rendering for supported run commands
- interactive command header rendering for supported run commands
- explicit log-path notice rendering for supported run commands via backend metadata
- optional rolling mini-log rendering for supported run commands via `--tail`
- collapse of the rolling mini-log back to a compact log-path line on successful completion
- compact frontend completion summaries for interactive run commands
- lightweight CPU/RAM telemetry on the spinner line for interactive run commands
- a double-escape interruption window of 3 seconds, with the spinner hint switching between `esc interrupt` and `esc again to interrupt`

## Verified Through The Rust Binary

These paths were verified through the installed Rust binary:

- `makevn help`
- `makevn --help`
- `makevn --repo /path/to/repo doctor`
- `makevn --repo /path/to/repo compile`
- `makevn --repo /path/to/repo build`

Verification included:

- a real repository check against `mic-icdmmeasurementtemplates` for `doctor`
- a controlled temporary repo with a fake `mvnw` for `compile`
- an interactive temporary repo with a fake `mvnw` for `build`, including Rust-owned loader/header rendering and double-escape interruption
- temporary-repo verification for sequential command dispatch and per-command managed logs

## Install And Build Flow

Current source-checkout flow:

```bash
./build-rust-dispatcher.sh
./install.sh --rust
```

Installer modes:

- `./install.sh` installs Rust if `target/release/makevn` already exists, otherwise falls back to shell
- `./install.sh --rust` requires the Rust binary and fails if it is missing
- `./install.sh --shell` forces the shell entrypoint

Important:

- `install.sh` does not compile Rust
- Rust compilation is intentionally separated into `./build-rust-dispatcher.sh`

## Internal Boundary Today

Implemented today:

- `backend.sh BACKEND_COMMAND --repo ABS_PATH ...`
- absolute repo-path requirement at the backend boundary
- backend command validation
- transitional passthrough into `cli.sh`
- `--metadata-out` support for Rust-owned interactive run commands
- backend metadata written before delegated run-command launch

Not implemented yet at the backend boundary:

- `--format json`
- `--log-path`

## Known Limitations

- run commands already route through Rust and `backend.sh`, but delegated repository-aware execution is still shell-owned
- interactive run-command loader, command header, compact log-path summaries for tailed commands, optional `--tail` mini-log, and lightweight per-command resource telemetry are now frontend-owned in Rust, but the backend still chooses the log file path
- `doctor` is still rendered by the shell backend in text mode
- no public `--json` behavior exists yet
- `target/release/makevn` is not a standalone distributable artifact by itself; it still expects the runtime layout installed alongside it

## Recommended Next Steps

Recommended next implementation step:

1. Add real `--format json` support for state commands at `backend.sh` and backend implementation level, starting with `doctor`
2. Add frontend `--json` handling for `doctor`
3. Then move to `compile --json` with the eventual explicit `--log-path` contract

Do not revisit in the next session unless requested:

1. keep the current command-chain syntax and compatibility behavior for trailing global `--tail`
2. keep the current `--tail` UX: successful commands should settle to `:: log: ...` plus `[ok] <duration>` on completion

User preference for the next session:

1. continue with the mini-log option rendered inside the frontend, keeping the default collapsed view unless `--tail` is requested and preserving the current spinner/resource layout
2. keep `doctor` logic in backend scripting and only change how data is sent to the frontend

If the goal is user-visible progress instead of backend contract progress, the alternative path is:

1. implement `compile --json` end to end
2. then implement `doctor --json`

## Files To Read Next

For the next session, read these in order:

1. `docs/rust-transition-status.md`
2. `docs/backend-contract.md`
3. `docs/cli-contract.md`
4. `rust/dispatcher/src/main.rs`
5. `libexec/makevn/backend.sh`
6. `libexec/makevn/common.sh`

## Short Resume Prompt

Resume the Rust frontend transition for `makevn` from `docs/rust-transition-status.md`. Keep `backend.sh` as the stable shell entrypoint, preserve the current public CLI contract, keep `doctor` logic in backend scripting, and continue with the next smallest verified step toward `--json` support while preserving the current frontend UX: command chaining, compact tailed-command summaries as `:: log: ...` plus `[ok] <duration>`, spinner-bottom layout, per-command CPU/RAM telemetry, and 3-second double-escape interruption handling.
