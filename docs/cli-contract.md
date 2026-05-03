# CLI Contract

## Purpose

This document freezes the intended public CLI contract for `makevn` as the project moves from a shell-first CLI entrypoint to a Rust frontend with a shell execution backend.

It serves two goals:

- preserve a stable command surface for humans, advanced developers, and AI agents
- make future implementation changes explicit instead of accidental

## Status

This contract is a mix of:

- current behavior that already exists in the shell implementation
- target behavior that the Rust frontend should implement while preserving the public command model

Current implemented frontend-owned behavior already includes:

- `--version`
- global `--help`
- `help`
- public command validation for the known command surface
- repo-path normalization before backend invocation
- dispatch through the internal `libexec/makevn/backend.sh` entrypoint
- interactive loader rendering for supported run commands
- interactive command header and log-path header rendering for supported run commands

Current repository-aware commands already verified through the Rust frontend include:

- `doctor`
- `compile`
- `build`

Target-state items in this document include:

- `--json` on every public command
- `--no-color` as a frontend-owned global flag
- `--tail` as an optional frontend-owned log-following mode

## Scope

This contract applies to the installed `makevn` binary on:

- `macOS`
- `Linux`
- `Windows` through WSL

It does not define native `Windows` support outside WSL.

## Public Entry Point

The public entry point is:

```bash
makevn
```

The installed binary is the canonical interface for:

- humans
- AI agents
- optional `make` integration through generated `vn-*` targets

The AI skill is guidance, not a required runtime dependency.

## Global Syntax

The frontend should preserve this global shape:

```bash
makevn [GLOBAL_OPTIONS] COMMAND [COMMAND_OPTIONS] COMMAND [COMMAND_OPTIONS] ...
```

Compatibility sugar that is still accepted:

```bash
makevn COMMAND [COMMAND_OPTIONS] COMMAND [COMMAND_OPTIONS] ... [GLOBAL_OPTIONS]
```

Global options:

- `--repo PATH`
- `--help`, `-h`
- `--version`
- `--json`
- `--no-color`
- `--tail`

Global option rules:

- `--repo` selects the repository root to operate on
- `--help` prints help and exits `0`
- `--version` prints the CLI version and exits `0`
- `--json` switches output to structured machine-readable output
- `--no-color` disables ANSI color in human-oriented output
- `--tail` enables optional colorized log following for supported long-running commands
- when `--tail` is used as a global option, it applies to every managed-log command in the chain
- command-local options remain attached to the command they follow
- `--` remains command-local and ends command chaining for the rest of that command's delegated arguments

## Public Commands

### Repository Analysis And Integration

```bash
makevn doctor
makevn init --mode MODE [--dry-run] [--write-make-include] [--force]
makevn uninstall [--dry-run]
makevn profile refresh
```

Mode values:

- `standalone`
- `make-include`
- `make-bootstrap`
- `auto`

### Maven-Oriented Commands

These commands accept extra Maven arguments after `--`:

```bash
makevn compile [-- EXTRA_MAVEN_ARGS...]
makevn test-compile [-- EXTRA_MAVEN_ARGS...]
makevn compile-tests [-- EXTRA_MAVEN_ARGS...]
makevn validate [-- EXTRA_MAVEN_ARGS...]
makevn package [-- EXTRA_MAVEN_ARGS...]
makevn build [-- EXTRA_MAVEN_ARGS...]
makevn clean [-- EXTRA_MAVEN_ARGS...]
makevn verify-ut [-- EXTRA_MAVEN_ARGS...]
makevn verify-ut-coverage [-- EXTRA_MAVEN_ARGS...]
makevn verify-it [-- EXTRA_MAVEN_ARGS...]
makevn verify-it-coverage [-- EXTRA_MAVEN_ARGS...]
makevn verify [-- EXTRA_MAVEN_ARGS...]
makevn verify-changes [-- EXTRA_MAVEN_ARGS...]
makevn pr-verify [-- EXTRA_MAVEN_ARGS...]
```

### Karate Commands

These commands are optional and require a detected Karate Maven project (`e2e/karate/pom.xml` or `karate/pom.xml`):

```bash
makevn karate-up
makevn karate-down
makevn karate-test [--tag TAG] [-- EXTRA_MAVEN_ARGS...]
makevn karate-all [--tag TAG] [-- EXTRA_MAVEN_ARGS...]
makevn run-app
makevn run-app-bg
makevn stop-app
```

`karate-up` and `karate-down` use the detected E2E compose file and include a sibling `docker-compose.override.yml` when present. `karate-test --tag @tag` maps to Karate's tag filtering.

`run-app-bg` starts the built application jar, records its PID under `.makevn/app/`, waits for `/amiga/health`, and returns so it can be chained before `karate-test`. `stop-app` validates the recorded jar before stopping the process. `karate-all` composes `karate-up`, `package` unless `SKIP_PACKAGE=true`, `run-app-bg`, `karate-test`, and `stop-app`.

### Coverage Analysis Commands

```bash
makevn coverage-changes [--threshold PCT]
```

`coverage-changes` requires an existing JaCoCo aggregate report. If the aggregate module has already been built but the HTML report is missing, the backend may run `jacoco:report-aggregate` for the detected aggregate module before analysis. The command compares changed Java production code against the detected parent branch and uses the internal coverage runtime packaged under `libexec/makevn/`.

`verify-changes` owns its repository-aware command construction in the backend and keeps an internal compatibility runtime script packaged at `libexec/makevn/compat/verify_changes.sh` for parity and future consolidation. It must not call or depend on a target repository's `scripts/make/*` files.

These commands may also be chained sequentially in one invocation:

```bash
makevn clean verify-it
makevn --tail clean verify-it
makevn clean --tail verify-it
makevn clean verify-it --tail
```

Chaining rules:

- commands run sequentially in the order written
- execution stops at the first non-zero exit code
- command-local options apply only to the command they follow
- trailing global options apply to the whole chain as compatibility sugar

Verification intent:

- `verify-ut` is the unit-test-only verification path
- `verify-it` is the integration-test-only verification path
- `verify` is the combined verification path and should run both suites according to the repository workflow
- `verify` should reject UT/IT skip flags such as `-DskipUTs`, `-DskipITs`, and `-Dskip.unit.tests=true` because those belong to the split workflows instead

### Test Command

```bash
makevn test [--name TEST]... [--fast] [-- EXTRA_MAVEN_ARGS...]
```

Rules:

- no `--name` means full test execution
- `--name FooTest` selects one test
- `--name FooTest,BarTest` selects multiple tests sequentially
- repeated `--name` flags are allowed
- `--fast` requires at least one selected test

### Command Execution

```bash
makevn exec [--context code|karate] -- COMMAND [ARGS...]
makevn run
```

Rules:

- `exec` requires `--` before the delegated command
- `run` executes the configured repository run command

### Docker Helpers

```bash
makevn docker-up
makevn docker-down
makevn docker-ps
makevn docker-ps-required
```

### JDK Commands

```bash
makevn jdk current
makevn jdk list
```

## Output Modes

### Default Human Mode

Default output is human-readable terminal text.

Properties:

- line-oriented
- concise
- stable enough to read and troubleshoot manually
- colorized when supported unless `--no-color` is used

Markdown is not a CLI output contract.

### JSON Mode

Every public command should accept `--json`.

Rules:

- when `--json` is active, `stdout` is reserved for JSON or NDJSON only
- human-only prose should not be mixed into `stdout`
- additive fields are allowed in future versions; removals and semantic renames should be avoided

#### Single-Document JSON Commands

Commands that primarily return state should emit a single JSON document.

Initial set:

- `doctor --json`
- `init --json`
- `init --dry-run --json`
- `uninstall --json`
- `uninstall --dry-run --json`
- `profile refresh --json`
- `jdk current --json`
- `jdk list --json`
- `docker-ps --json`
- `docker-ps-required --json`

Minimum envelope:

```json
{
  "command": "doctor",
  "repo": "/abs/path",
  "ok": true,
  "version": "0.1.0-dev"
}
```

Recommended command-specific fields:

- `doctor`: `supported`, `recommended_mode`, `current_mode`, `maven_base_path`, `makefiles`, `detected_profile`, `jdk`
- `init`: `dry_run`, `resolved_mode`, `created`, `updated`, `would_create`, `would_update`
- `uninstall`: `dry_run`, `removed`, `updated`, `would_remove`, `would_update`, `managed_assets`
- `profile refresh`: `profile_path`, `cache_source`, `workflow_files`
- `jdk current`: `global_java_home`, `code`, `karate`
- `jdk list`: `jdks`
- `docker-ps`: `services`
- `docker-ps-required`: `services`

#### NDJSON Commands

Commands that execute work over time should emit NDJSON event streams.

Initial set:

- `compile --json`
- `test-compile --json`
- `compile-tests --json`
- `validate --json`
- `package --json`
- `build --json`
- `clean --json`
- `test --json`
- `verify-ut --json`
- `verify-ut-coverage --json`
- `verify-it --json`
- `verify-it-coverage --json`
- `verify --json`
- `verify-changes --json`
- `coverage-changes --json`
- `pr-verify --json`
- `exec --json`
- `run --json`
- `docker-up --json`
- `docker-down --json`

Each line must be a complete JSON object.

Minimum common fields on every event:

```json
{
  "event": "started",
  "command": "build",
  "repo": "/abs/path",
  "ts": "2026-04-30T12:00:00Z"
}
```

Stable event families:

- `started`
- `exec`
- `log`
- `progress`
- `completed`
- `failed`
- `cancelled`

Expected event meaning:

- `started`: command accepted and execution is beginning
- `exec`: delegated child command or step is known
- `log`: managed log path is known
- `progress`: optional high-level milestone information
- `completed`: successful completion
- `failed`: non-zero completion
- `cancelled`: user interruption or explicit cancellation

Recommended event fields:

- `started`: `argv`, `context`
- `exec`: `argv`, `cwd`
- `log`: `path`, `relative_path`
- `progress`: `step`, `message`
- `completed`: `exit_code`, `duration_ms`
- `failed`: `exit_code`, `duration_ms`, `message`
- `cancelled`: `exit_code`, `duration_ms`

Example:

```json
{"event":"started","command":"build","repo":"/repo","ts":"2026-04-30T12:00:00Z"}
{"event":"log","command":"build","repo":"/repo","ts":"2026-04-30T12:00:00Z","path":"/repo/.makevn/logs/build.log","relative_path":".makevn/logs/build.log"}
{"event":"exec","command":"build","repo":"/repo","ts":"2026-04-30T12:00:00Z","argv":["./mvnw","-f","/repo/pom.xml","package","-DskipTests"]}
{"event":"completed","command":"build","repo":"/repo","ts":"2026-04-30T12:00:18Z","exit_code":0,"duration_ms":18342}
```

## Tail Mode

`--tail` is an optional human-oriented mode.

Purpose:

- follow the existing managed log file in place
- keep a compact rolling view of the most recent log output in the terminal
- improve local UX without changing the backend logging contract

Rules:

- `--tail` must be rejected when combined with `--json`
- `--tail` uses the interactive mini-log only when a TTY is available; without a TTY it must degrade to normal command execution
- `--tail` is only valid for commands that produce a managed log file
- the preferred public syntax is `makevn [global_options] command [options] command [options] ...`
- `--tail` may be provided as a global option before the command chain and applies to every managed-log command in the chain
- `--tail` may also be accepted at the end of the command chain as compatibility sugar with the same global meaning
- the backend remains responsible for writing the log
- `--tail` must not change the final exit code of the underlying command
- the default view should show a small rolling window of about 3-4 lines
- users can expand the view on demand for more context without leaving the command
- when `--tail` is enabled, the visible settled output for each successful command should remain compact as `:: log: <relative_path>` plus `[ok] <duration>`
- successful interactive completion can be summarized compactly as `[ok] <duration>`
- the spinner line may include lightweight CPU and RAM telemetry for the running backend process tree
- the double-escape interruption window is 3 seconds

Example lifecycle for a successful tailed command:

```text
:: makevn clean
:: log: .makevn/logs/clean.log
[ok] 4s
```

Initially supported command family:

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
- `pr-verify`
- `karate-test`

Commands such as `doctor`, `init`, `uninstall`, `profile refresh`, `coverage-changes`, `jdk current`, `jdk list`, `docker-ps`, `docker-ps-required`, `karate-up`, `karate-down`, `karate-all`, `run-app`, `run-app-bg`, and `stop-app` should reject `--tail`.

`exec`, `run`, `docker-up`, and `docker-down` may gain `--tail` support later if they are routed through the same managed log model, but that support is not assumed by this frozen contract.

## Exit Codes

The exit-code contract should stay small.

- `0`: success
- `1`: `makevn` validation error, setup error, or generic command failure when no more specific delegated exit code is available
- `130`: user interruption or cancellation
- any other non-zero code: preserved delegated process exit code when practical

Implications:

- if Maven exits with a non-zero code, `makevn` should preserve it when practical
- if a delegated command exits `130`, `makevn` should treat that as cancellation
- bad CLI usage should return `1`, not a human-only special code family

## Compatibility Rules

The following are considered stable:

- command names
- top-level subcommand structure
- main meaning of existing flags
- the existence of `--json` on every public command
- the distinction between single-document JSON commands and NDJSON long-running commands
- the incompatibility between `--json` and `--tail`

The following may evolve additively:

- extra JSON fields
- extra NDJSON event fields
- additional `progress` events
- future `--tail` support for more commands that adopt managed log output

## Agent Guidance

For AI agents, the intended preference order is:

1. use the installed `makevn` binary directly
2. use `--json` when structured decisions are needed
3. avoid `--tail` unless a human explicitly requests an interactive local view
4. use the skill for workflow policy, not for parsing CLI output
