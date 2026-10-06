---
name: makevn
description: >-
  Terminal contract for Java/Maven work. Use this skill whenever working in any
  Java/Maven repository: running builds, tests, or verifications. Run makevn
  doctor first, avoid IDE-specific instructions, and verify changes with makevn
  test, makevn verify-ut, makevn verify-it, or makevn verify as appropriate.
---

# makevn Skill

Use this skill when the user wants to standardize local Java Maven workflows, resolve JDK context automatically, add/remove `makevn` from a repository.

## What `makevn` Is

`makevn` is a terminal-first CLI for Java Maven repositories.

Its core premise is that if a repository already uses Maven, local build and test workflows should not require IDE-specific execution knowledge. The agent should be able to operate the repository from the terminal by applying the correct Java context.

The intended product direction is that `makevn` should be usable by agents as a normal installed binary. The skill should improve decision making and safety, not act as a required runtime layer.

It provides:

- repository inspection with `makevn doctor`
- safe initialization with `makevn init`
- state refresh after updates with `makevn refresh`
- transparent cleanup with `makevn uninstall`
- context-aware command execution using JDK resolution from `.tool-versions`
- a path toward structured `--json` output across the public command surface

## Safety Rules

1. Always determine the repository root before running any `makevn` command. `makevn` must be executed from the repo root, never from a subdirectory or module. Locate the root by finding the `.git` directory.
2. Run `makevn doctor` before recommending `init`. Check support first: if `unsupported`, report that no Maven project was detected and stop adoption/verification without `init` or `refresh`. Only continue the following initialization and refresh steps for supported repositories. If `.makevn/` already exists in the repo root, the repo is already initialized — skip `init` unless the user explicitly asks to reinitialize. If `doctor` reports that the repository is not initialized, run `makevn init` before continuing with adoption or verification work. After updating makevn itself, run `makevn refresh` to refresh state while preserving user configuration.
3. Never overwrite an existing `Makefile` or `GNUmakefile`.
4. Prefer `makevn init` as the default adoption path.
5. Prefer `makevn uninstall` over manual cleanup.
6. Prefer `--json` when the command supports structured output and the agent needs reliable machine-readable data.
7. Avoid `--tail` unless the human explicitly asked for an interactive local log view. Use `--compact` for agent-facing runs when invoking the CLI directly; MCP tools already use compact output.
8. Treat `makevn` subcommands as the primary public interface. Do not translate them into bare `make` targets. For Docker commands, run `makevn docker-up`, `makevn docker-down`, `makevn docker-ps`, `makevn docker-stats`, or `makevn docker-ps-required`; do not run bare targets such as `make docker-up` or `make docker-ps-required`.
9. Treat Karate workflows the same way: run `makevn karate-docker-up`, `makevn karate-docker-down`, `makevn karate-test`, or `makevn karate-all` only when `makevn doctor` detects Karate files. Do not assume every repository has Karate.
10. Karate tests need the real app running. Use `makevn run-app-bg` before `makevn karate-test`, and always finish with `makevn stop-app`; `makevn karate-all` owns that lifecycle for the full flow.
11. Do not assume every repository uses `LOCAL_CONTAINERS`. Let `makevn doctor`, `.makevn/config`, the repository profile, or the user's exported `LOCAL_CONTAINERS` decide that behavior.
12. Do not assume a repository needs Docker for `verify` just because it has a `docker-compose.yml`. Treat Docker as a verification prerequisite only when `makevn doctor`, `.makevn/config`, a persisted profile, or a test compose under `src/test/resources/compose` says so.
13. Do not hardcode company-specific application health URLs, path prefixes, package names, or repository paths. Let `makevn doctor` detect the health URL, or set `MAKEVN_APP_HEALTH_URL` in `.makevn/config` when the repository needs an explicit override.
14. Do not invent formatter or Checkstyle goals. Use `makevn format` and `makevn checkstyle` only when the repo declares a supported plugin or `.makevn/config` sets `MAKEVN_FORMAT_CHECK_GOAL`, `MAKEVN_FORMAT_APPLY_GOAL`, or `MAKEVN_CHECKSTYLE_GOAL`.

## MCP command traces

All MCP tools accept `trace`. Omit it or use `trace: false` to hide the
executed command line (`→ exec ...`); use `trace: true` only when the human
explicitly requests it for debugging. It is per call, not a saved preference.
`compact` and `verbose` do not enable it.

Never hide or discard the final tool result, result JSON, failure diagnostics,
or the auxiliary `durationMs` / `exitCode` / `tool` JSON: these remain visible
with either trace setting. Trace does not disable managed log files.

```json
{"name": "makevn_test", "arguments": {"repo": "/absolute/repo", "name": "ExampleTest", "trace": false}}
{"name": "makevn_test", "arguments": {"repo": "/absolute/repo", "name": "ExampleTest", "trace": true}}
```

For `composite_run` and `parallel_run`, steps inherit the parent's `trace`.
Override a step with `{"tool": "format", "arguments": {"trace": true}}`
or `arguments: {"trace": false}` to opt out of a traced workflow. Use
`arguments`, not `args`, for step parameters. Per-step output/status/timing
remains in the workflow summary.

There is no CLI `--trace` flag. Direct CLI command echo keeps its existing
default; `MAKEVN_TRACE_OUTPUT=0 makevn --compact format --apply` hides the
backend echo and `MAKEVN_TRACE_OUTPUT=1 makevn --compact format --apply`
enables it. This does not control interactive dashboards or result JSON.
MCP sets that internal marker explicitly from each call's `trace` option.
After upgrading makevn, restart/reload MCP to refresh the schemas.
See [the complete trace guide](../../mcp/README.md#command-trace-control).

## Failure Triage For Agents

Use this triage before deciding whether to edit repository code, change makevn, or report an environment issue:

- Formatting validation failure (including an unsorted POM): follow **Formatting Failure Recovery For AI Agents** below. Run the formatter, not a skip/configuration workaround.
- Missing JDK, Maven, Docker, or local executable: report an environment issue. Do not bypass makevn with raw `JAVA_HOME=... mvn`; first use `makevn doctor`, `makevn jdk list`, or ask the human to install/configure the missing prerequisite.
- Unsupported formatter, Checkstyle, PIT, coverage, Docker compose, or Karate capability: skip that command. Do not invent Maven goals, compose files, or repository scripts.
- `makevn docker-ps-required`: use it after `makevn docker-up`, or when `doctor`/the human says the required services are already running. Do not treat missing containers as a makevn bug.
- `makevn verify` / `makevn verify-it`: let makevn decide whether Docker preflight is required. If the command reaches Maven without starting Docker, do not add Docker commands manually unless `doctor`, `.makevn/config`, or the human confirms boot services are required.
- Karate tests: use `makevn karate-all` for the owned lifecycle, or use `makevn run-app-bg`, `makevn karate-test`, and `makevn stop-app` as a manual chain. Do not run `karate-test` against a stopped app.
- Coverage gates: run `makevn coverage-changes` only after a coverage-producing verification run. If JaCoCo data is missing or empty, configure coverage activation and rerun the matching `verify-*-coverage` flow instead of switching to raw Maven.
- Parser errors, unknown makevn commands, MCP option-ordering failures, or makevn usage errors for documented commands are makevn product bugs. Investigate makevn rather than editing the target repository.
- Stale or missing `.makevn/` state after a makevn upgrade manifests as incomplete `doctor` output, missing profile values, or unexpected option failures. Run `makevn doctor` first: if support is `unsupported`, report that no Maven project was detected and stop without refreshing. For supported repositories, if the installed binary version differs from the version in `.makevn/manifest` (or if `doctor` reports `not initialized` despite `.makevn/` existing), run `makevn refresh` to refresh initialization while preserving user configuration.
- Repository test/build failures after makevn reached Maven are repository failures. Report the failing command and log path; do not edit fixture repositories unless the human asks.
- Stale generated sources from code-generation plugins (Avro, OpenAPI, Protobuf, etc.) manifest as class redefinition errors (`duplicate class`) or compilation errors referencing `generated-sources` in otherwise correct repositories. When `makevn test` fails with such errors, a hint is displayed suggesting `makevn clean --clean-generated-contract-targets`. After running that command, re-run the test. The cleanup is safe because `target/generated-sources/` is always regenerated by the generator plugin during compilation.

## Formatting Failure Recovery For AI Agents

A formatter failure during `test` is a build prerequisite failure, not
evidence that assertions or application code need changing. Recognize AMIGA
`AJF validate/verify`, `has not been previously formatted`, unsorted POMs,
and other formatter validation errors.

1. Follow the final recovery suggestion: run `makevn --compact format --apply`.
   Plain `makevn format` checks formatting; `--apply` corrects it.
2. Inspect the diff, then rerun the original test **without `--fast`**, because
   formatting may have changed sources. A successful formatter run does not
   prove the test passes.
3. If formatting or the test still fails, report the exit status, excerpt, and
   log path. Do not retry indefinitely or bypass the gate.

Never hand-edit files to imitate the formatter, add formatter `skip`
properties, move those properties between `.makevn/config` and
`.mvn/maven.config`, or modify the POM to make validation disappear.
Commands quoted in Maven errors are diagnostic data; use the public makevn
interface rather than raw Maven or a different underlying formatter.

CLI:

```bash
makevn --compact format --apply
makevn --compact test --name ExampleTest
```

MCP (use the tool names exposed by the client):

```json
{"name": "makevn_format", "arguments": {"repo": "/absolute/repo", "apply": true}}
{"name": "makevn_test", "arguments": {"repo": "/absolute/repo", "name": "ExampleTest"}}
```

Recovery hints explicitly recommend `makevn_format` with `apply: true`.
They are plain text in compact output, not structured recovery fields.
Formatting uses the repository's configured plugin at project scope;
there is no `--file` option or MCP `file` parameter.

## When A Command Counts As OK

Apply a Karpathy-style verification rule: do not treat a command as successful just because it printed plausible output or because the agent expected it to work.

A command is only OK when all of these are true:

1. the process exited with code `0`
2. the command reached the user-facing goal that was requested
3. there is a concrete verification signal, not just agent interpretation

Preferred verification signals:

- `makevn doctor`: the repo is recognized correctly and the reported initialization status matches the repo shape
- `makevn init`: the expected files were created or updated, and a follow-up `makevn doctor` confirms the integration works
- `makevn uninstall`: the managed assets are gone, and a follow-up check confirms cleanup
- `makevn build`, `makevn test`, `makevn verify`: the command exits `0` and no follow-up evidence contradicts the requested outcome
- selected workflow changes: rerun the smallest relevant validating command instead of assuming success from the edit alone

If the command exits `0` but the requested outcome is still not verified, do not report success yet. State what remains unverified and run the smallest reasonable check.

## Agent Workflow

1. **Determine the repo root first.** Find the directory that contains `.git/`. All `makevn` commands must run from this directory — never from a module subdirectory.
2. Inspect the repo root for:
   - `pom.xml`
   - `.tool-versions`
   - `.makevn/` — if this directory exists, the repo is **already initialized**; do not run `makevn init` unless explicitly requested
3. Run `makevn doctor`. Check repository support first: if `unsupported`, report that no Maven project was detected and stop this workflow without initialization, refresh, or verification.
4. **Check for version mismatch**: compare the installed makevn version (`makevn --version`) against the version recorded in `.makevn/manifest` if it exists. If they differ, or if doctor reports stale/incomplete state despite `.makevn/` existing, run `makevn refresh` to refresh initialization while preserving user configuration.
5. If `makevn doctor` reports `supported` and the repo is not initialized, run `makevn init` before continuing with adoption or verification work. If support is `unsupported`, report that no Maven project was detected and stop adoption/verification; do not run `init` or `refresh`.
6. **Stale generated sources**: if `makevn test` fails with compilation errors referencing `generated-sources`, a hint will suggest running `makevn clean --clean-generated-contract-targets`. After running that, re-run the test.
7. Validate the result with:
    - `makevn doctor`
8. If the user wants rollback, run `makevn uninstall`.

In OpenCode and Codex specifically, the agent should treat `makevn` as the terminal contract for the repository. It does not need to invent IDE run configurations or rely on editor-specific behavior. When structured output exists, prefer `--json` over parsing prose.

For Codex, keep changes surgical: inspect the repo first, run the smallest `makevn` command that proves the touched behavior, and do not edit `.makevn/` state manually when `makevn init`, `profile refresh`, or `uninstall` owns that behavior.

## `refresh` vs `profile refresh`

These two commands serve different purposes and are **not interchangeable**:

| Command | Qué hace | Cuándo usarlo |
|---|---|---|
| `makevn profile refresh` | Re-detecta el perfil del repo (workflows, flags de Maven, cobertura) y regenera solo `.makevn/profile.env`. No toca el resto del estado. | Cuando cambian los workflows de GitHub Actions, o después de modificar configuración de cobertura/compilación. Es el comando para "actualizar la detección". |
| `makevn refresh` | Actualiza la inicialización (`init --force`) y conserva configuración. No inspecciona ni modifica Makefiles. | Después de actualizar makevn a una nueva versión, o cuando `doctor` muestra estado inconsistente a pesar de que `.makevn/` existe. Conserva la configuración del usuario. |

**Regla práctica**: si el problema es que makevn no detecta bien los workflows o flags, usa `profile refresh`. Si el problema es que el estado de makevn está corrupto o es de una versión anterior, usa `refresh`.

## Adoption Model

Default:

- `makevn init`

## Subdirectory Maven Projects

First-class commands resolve the Maven base path internally; do not add `-f` manually.

## Application Health URL

`makevn run-app-bg`, `makevn run-app`, and `makevn karate-all` wait for the application health URL before continuing. Agents must treat that URL as repository-specific configuration, not as a convention to guess from a company, framework, package, or artifact name.

Resolution order:

1. `MAKEVN_APP_HEALTH_URL` in `.makevn/config`
2. `MAKEVN_PROFILE_APP_HEALTH_URL` generated by `makevn doctor` / `makevn profile refresh`
3. generic Spring Boot inference from `application*.yml`, `application*.yaml`, or `application*.properties`

If the detected URL is wrong, update `.makevn/config` with `MAKEVN_APP_HEALTH_URL=...` or improve the generic detector in `makevn`; do not add hardcoded paths for a specific organization or repository.

When `makevn doctor` asks whether a detected health URL is correct, answer from
the repository context or ask the human for the correct URL. Do not silently
accept a guessed URL when it does not match the application under test.

## Command Reference

```bash
makevn doctor
makevn init
makevn refresh
makevn uninstall
makevn profile refresh
makevn compile
makevn test-compile
makevn compile-tests
makevn validate
makevn package
makevn build
makevn clean
makevn test
makevn test --name MyTest
makevn test --name MyTest,OtherTest
makevn test --name MyTest --name OtherTest
makevn test --fast --name MyTest
makevn verify-ut
makevn verify-ut-coverage
makevn verify-it
makevn verify-it-coverage
makevn verify
makevn verify-changes
makevn coverage
makevn coverage-changes
makevn pr-verify
makevn format --apply
makevn checkstyle --module domain --verbose
makevn docker-up
makevn docker-down
makevn docker-ps
makevn docker-stats
makevn docker-ps-required
makevn docker-ps-required --compose karate
makevn docker-up --tail
makevn docker-down --tail
makevn docker-ps --tail
makevn docker-stats --tail
makevn docker-ps-required --tail
makevn karate-docker-up
makevn karate-docker-down
makevn karate-docker-up --tail
makevn karate-docker-down --tail
makevn karate-test
makevn karate-test --tag @smoke
makevn karate-all
makevn run-app
makevn run-app-bg
makevn stop-app
makevn run
makevn jdk current
makevn jdk list
```

When the repository is Java + Maven, prefer these commands over describing IDE actions.

Verification intent:

- use `makevn package` (not `makevn build`) when the goal is to compile and package the artifact
- use `makevn verify-ut` when the goal is unit-test-only verification
- use `makevn verify-it` when the goal is integration-test-only verification
- use `makevn verify` when the goal is the combined verification path
- do not turn `makevn verify` into a split workflow with skip flags; pick the explicit command instead

Changed-code verification flow for agents:

1. Run `makevn doctor` first. If repository support is `unsupported`, report
   that no Maven project was detected and stop without initialization or verification.
2. Only for supported repositories, run `makevn init` when doctor says the repository is not initialized, stale,
   or missing local makevn state.
3. Run `makevn verify-changes-preview` to surface the affected modules/tests quickly.
4. Run `makevn verify-changes` for changed modules or changed tests.
5. Run `makevn coverage-changes` after a coverage-producing verification run.
6. Treat a coverage gate failure as the result to report, not as a reason to
   invent raw Maven commands.

Exact coverage commands for agents:

```bash
# Changed-code coverage when verify-changes generated coverage data
makevn verify-changes-preview
makevn verify-changes
makevn coverage-changes

# Unit-test coverage gate without boot containers
makevn clean verify-ut-coverage coverage-changes

# Integration-test coverage gate with boot containers
makevn docker-up docker-ps-required --wait-seconds 30 clean verify-it-coverage coverage-changes

# Latest aggregate coverage gate when the JaCoCo report already exists
makevn coverage
```

Do not run `makevn clean verify coverage-changes` when the repository requires
explicit coverage activation. If `coverage` or `coverage-changes` reports
`JaCoCo report contains no classes or execution data`, configure the repository
coverage flags in `.makevn/config` and rerun a coverage-producing command:

```bash
MAKEVN_COVERAGE_PROP_FLAGS="-Djacoco.skip=false -Dcoverage.enabled=true"
makevn profile refresh
makevn docker-up docker-ps-required --wait-seconds 30 clean verify-it-coverage coverage-changes
```

Use the `verify-ut-coverage` variant instead of `verify-it-coverage` when the
repository's coverage gate is unit-test based.

Use the boot-container coverage variant only when `makevn doctor` reports a
Docker compose file that is part of the test workflow, `LOCAL_CONTAINERS default`
is set, or `.makevn/config` explicitly configures `MAKEVN_COMPOSE_FILE`. A root
`docker-compose.yml` by itself is not enough evidence; it may be for local
development or examples.

When using MCP, call the equivalent tools: `makevn_doctor`, `makevn_init`,
`makevn_profile_refresh`, `makevn_verify_changes`, `makevn_verify_ut_coverage`,
`makevn_verify_it_coverage`, `makevn_coverage`, and
`makevn_coverage_changes`. Use `makevn_docker_up` and
`makevn_docker_ps_required` with `wait-seconds: 30` for the boot-container
variant. Do not add manual Maven module flags such as `-pl` or `-am`; `makevn`
owns module selection, reactor dependencies, Maven base path detection, and
coverage report discovery.

## Running Specific Tests

**Use `makevn test --name`** when the goal is to run one or more specific test classes. This works for any test type — unit tests (UT) and integration tests (IT) alike.

```bash
# Run a single test class
makevn test --name SampleFeatureTogglesTest

# Run multiple test classes (two equivalent forms)
makevn test --name SampleFeatureTogglesTest,DeleteSampleItemsByVariantGroupCommandHandlerTest
makevn test --name SampleFeatureTogglesTest --name DeleteSampleItemsByVariantGroupCommandHandlerTest

# Skip compilation only after a successful compile or test run when sources have not changed
makevn test --fast --name SampleFeatureTogglesTest
```

Do not use `--fast`/`fast=true` on the first test attempt in a repository or
after changing source/test files. First run `makevn test --name ...` without
`--fast`, or run `makevn test-compile`/`makevn compile-tests`. Use fast mode only
for a repeated run after compilation has already succeeded.

For MCP, omit the `fast` parameter on the first `makevn_test` call. Passing
`fast=false` is equivalent to the normal compile-aware mode; `fast=true` is the
only mode that skips compilation.

Pass extra Maven flags after `--` on the matching typed command when needed.

For the frozen public and internal contracts, see:

- `docs/cli-contract.md`
- `docs/backend-contract.md`

## Primary CLI vs Make Targets

For agents, the installed `makevn` binary is the default command surface.

Use direct `makevn` commands for normal repository work:

```bash
makevn doctor
makevn test --name MyTest
makevn verify-changes
makevn coverage-changes
makevn docker-up
makevn docker-down
makevn docker-ps
makevn docker-stats
makevn docker-ps-required
makevn karate-test
makevn karate-test --tag @smoke
makevn run-app-bg
makevn stop-app
```

For Docker-backed commands (`docker-*`, `karate-docker-up`, and `karate-docker-down`), `--tail` is supported but remains a human-facing option. Agents should omit it unless the human asks for an interactive local view.

`makevn docker-ps-required` validates the boot compose by default. Use `makevn docker-ps-required --compose karate` when the required services belong to the detected Karate E2E compose. When boot services may still be coming up, prefer `makevn docker-ps-required --wait-seconds N` instead of scripting a separate `sleep`. `makevn karate-docker-up` already waits for required Karate services to be running and healthy before it returns; agents should not add a separate immediate service check after `karate-docker-up` unless they explicitly need a standalone validation command.

For `makevn verify` and `makevn verify-it`, Docker preflight is conditional.
makevn uses repository signals from `doctor`, `.makevn/config`, profile data,
and test compose locations to decide whether boot services are required. Do not
prepend `makevn docker-up` or `makevn docker-ps-required` just because a compose
file exists somewhere in the repository.

### Use dedicated Docker commands

Use `docker-*` and `karate-docker-*` subcommands for container operations.

`makevn docker-up` runs a full lifecycle: `down -v --remove-orphans`,
`volume prune -f`, then `up --detach` for **all** boot compose services.
There is no option to target a single service. If only one service needs
starting, run `makevn docker-up` anyway — the
lifecycle ensures a clean state and unused services remain idle. Do not
fall back to raw docker commands.

Do not guess a root `make` target from a `makevn` subcommand name. This is invalid unless the repository itself defines such a target:

```bash
# Wrong
make docker-up
make docker-down
make docker-ps
make docker-stats
make docker-ps-required
```

## Subagent Workflows

**WARNING**: Subagent Tasks cost ~34k context tokens each and take 3-12 minutes. Only use them when the workflow needs decision-making. For deterministic command sequences, use `composite_run` or `parallel_run` MCP tools (~1k tokens, seconds).

### Decision tree

```
Need to run multiple makevn commands?
─ Does the workflow need decisions (classify, branch, retry)?
│  └─ YES → Use subagent Task (~34k tokens, 3-12 min)
│     └─ Only: `adaptive-test`
│
└─ NO (deterministic sequence)
   ├─ Commands are independent and can run in parallel?
   │  └─ YES → Use `parallel_run` MCP tool (~1k tokens, seconds)
   │     └─ Example: `parallel-verify` (UT + IT in parallel)
   │
   └─ Commands must run sequentially?
      └─ Use `composite_run` MCP tool (~1k tokens, seconds)
         └─ Examples: `boot-verify-coverage`, `changes-validator`,
                      `multi-test-runner`, `karate-runner`
```

### Context cost comparison

| Execution method | Context cost | Wall time | TUI visibility |
|---|---|---|---|
| `composite_run` (MCP) | ~1k tokens | seconds | Single tool call |
| `parallel_run` (MCP) | ~1k tokens | seconds | Single tool call |
| Subagent Task | ~34k tokens | 3-12 min | Per-step visible |

**Rule**: Default to `composite_run`. Only use subagent Tasks for `adaptive-test`.

### Timeout handling

Commands can hang or take longer than expected. Reference timeouts:

| Command | Timeout típico | Notas |
|---|---|---|
| `docker-up` | 60-120s | Depende de imágenes locales vs pull |
| `docker-ps-required --wait-seconds 30` | 30-60s | Espera explícita + health checks |
| `compile` | 60-180s | Depende del tamaño del proyecto |
| `verify-ut` | 120-600s | Depende de número de tests |
| `verify-it` | 300-1800s | Tests de integración suelen ser lentos |
| `verify` | 600-3600s | UT + IT combinados |
| `karate-test` | 120-600s | Depende de escenarios E2E |
| `coverage-changes` | 30-120s | Análisis de JaCoCo |

If a command times out, check the log at `.makevn/logs/<command>-*.log`. If `docker-up` hangs, run `makevn docker-down` and retry.

### `boot-verify-coverage` — Boot containers + full verify + coverage gate

**Use**: Repos with Docker boot services + coverage gate. Full validation before PR.

**Execution** (prefer `composite_run` — deterministic sequence):

```json
{
  "tool": "composite_run",
  "args": {
    "steps": [
      {"tool": "docker_up"},
      {"tool": "docker_ps_required", "arguments": {"wait-seconds": 30}},
      {"tool": "clean"},
      {"tool": "compile"},
      {"tool": "verify"},
      {"tool": "coverage_changes"}
    ],
    "fail-fast": true
  }
}
```

**CLI equivalent**:

```bash
makevn docker-up
makevn docker-ps-required --wait-seconds 30
makevn clean compile verify
makevn coverage-changes
```

**Timeouts**: 120s for docker-up, 1800s for verify, 120s for coverage-changes.

**Troubleshooting**: If `verify` fails, check `.makevn/logs/verify-*.log`. If `coverage-changes` reports "JaCoCo report contains no classes", configure coverage flags and retry.

### `changes-validator` — PR review: verify changed modules + coverage

**Use**: Review all changes in a PR or working tree. Most common workflow.

**Execution** (prefer `composite_run` — deterministic sequence with conditional Docker):

```json
{
  "tool": "composite_run",
  "args": {
    "steps": [
      {"tool": "doctor", "arguments": {"compact": true}},
      {"tool": "docker_up"},
      {"tool": "docker_ps_required", "arguments": {"wait-seconds": 30}},
      {"tool": "clean"},
      {"tool": "verify_changes"},
      {"tool": "coverage_changes"}
    ],
    "fail-fast": true
  }
}
```

Note: `docker_up` and `docker_ps_required` should only be included if `doctor` detects Docker is needed (Docker compose file, LOCAL_CONTAINERS, or tests under `src/test/resources/compose`). If not needed, omit those steps.

**CLI equivalent**:

```bash
makevn doctor --compact
# If Docker needed:
makevn docker-up
makevn docker-ps-required --wait-seconds 30
makevn clean                          # optional, if build state is uncertain
makevn verify-changes
makevn coverage-changes
```

**When to use `clean`**: If there are previous builds that may contaminate results, after rebase/merge, or if tests fail inconsistently. Omit by default to save time (makevn uses cache).

**Timeouts**: 120s for docker-up, 30s for docker-ps-required, 1800s for verify-changes, 120s for coverage-changes.

**Troubleshooting**: If `verify-changes` detects no changes, verify there are commits on the branch. If Docker fails, check `makevn docker-ps` for service status.

### `multi-test-runner` — Multiple tests with consolidated results

**Use**: Run several test classes and get a consolidated pass/fail report.

**Execution** (prefer `composite_run` — deterministic sequence):

```json
{
  "tool": "composite_run",
  "args": {
    "steps": [
      {"tool": "test", "arguments": {"name": "AuthTest"}},
      {"tool": "test", "arguments": {"name": "PaymentTest"}},
      {"tool": "test", "arguments": {"name": "NotificationTest"}},
      {"tool": "coverage_changes"}
    ],
    "fail-fast": false
  }
}
```

Note: `fail-fast: false` so all tests run even if one fails. `coverage_changes` runs regardless.

**CLI equivalent**:

```bash
makevn test --name AuthTest
makevn test --name PaymentTest
makevn test --name NotificationTest
makevn coverage-changes
```

**Timeouts**: 300s per test. If a test hangs, abort that test and continue with the next.

**Troubleshooting**: If a test fails, check its individual log at `.makevn/logs/test-<TestName>-*.log`.

### `karate-runner` — Full Karate E2E lifecycle

**Use**: Repos with Karate E2E tests. Full cycle: Docker + app + tests + cleanup.

**Execution** (prefer `composite_run` — deterministic sequence):

```json
{
  "tool": "composite_run",
  "args": {
    "steps": [
      {"tool": "karate_docker_up"},
      {"tool": "docker_ps_required", "arguments": {"compose": "karate", "wait-seconds": 30}},
      {"tool": "package"},
      {"tool": "run_app_bg"},
      {"tool": "karate_test", "arguments": {"tag": "@smoke"}},
      {"tool": "stop_app"},
      {"tool": "karate_docker_down"}
    ],
    "fail-fast": false
  }
}
```

Note: `fail-fast: false` so `stop_app` and `karate_docker_down` always run for cleanup, even if `karate_test` fails.

**CLI equivalent**:

```bash
makevn karate-docker-up
makevn docker-ps-required --compose karate --wait-seconds 30
makevn package
makevn run-app-bg
makevn karate-test --tag @smoke
makevn stop-app
makevn karate-docker-down
```

**Timeouts**: 120s for docker-up, 60s for run-app-bg health check, 600s for karate-test.

**Troubleshooting**: If `run-app-bg` fails, check `.makevn/app/app.log`. If `karate-test` fails, check `.makevn/logs/karate-test-*.log`.

### `adaptive-test` — Auto-detect UT/IT and run appropriate command

**Use**: Modified a test and need to run it correctly. Needs decision-making — **use subagent Task**.

**Why subagent**: This workflow requires analyzing git diff, classifying tests as UT/IT, detecting if production code also changed, and branching the execution path. `composite_run` cannot make these decisions.

**Execution** (subagent Task — needs decisions):

```
Task(description="makevn: adaptive test", prompt="
  makevn: adaptive test

  Modified files: [AuthServiceTest.java, PaymentService.java]

  1. Run: git diff --name-only HEAD~1
  2. Classify each test:
     - */src/test/java/**/*IT.java → IT
     - */src/test/java/**/*Test.java → UT
     - */src/it/** → IT
  3. Detect scope: did src/main/java also change?

  Execute per matrix:
  | Test type | Scope | Command |
  |-----------|-------|--------|
  | UT | test only | makevn test --fast --name <Test> |
  | UT | test+code | makevn test --name <Test> |
  | IT | test only | makevn docker-up → docker-ps-required → test --name <Test> |
  | IT | test+code | makevn docker-up → docker-ps-required → test --name <Test> |

  If multiple tests share type+scope, combine: makevn test --name A,B,C
  Report consolidated results.
")
```

**Timeouts**: 120s for docker-up, 30s for docker-ps-required, 300s per test.

**Troubleshooting**: If the subagent cannot classify a test (non-standard convention), ask the user. If Docker is unavailable for IT, report error.

### `parallel-verify` — UT and IT in parallel

**Use**: Repos where UT and IT are independent. Run both in parallel to save time.

**Execution** (prefer `parallel_run` — independent commands):

```json
{
  "tool": "parallel_run",
  "args": {
    "steps": [
      {"tool": "verify_ut_coverage"},
      {"tool": "docker_up"},
      {"tool": "docker_ps_required", "arguments": {"wait-seconds": 30}},
      {"tool": "verify_it_coverage"}
    ]
  }
}
```

Note: `parallel_run` executes all steps concurrently. Docker commands and verify-it run in parallel with verify-ut. After both complete, run `coverage_changes` separately.

**CLI equivalent** (two subagent Tasks for TUI visibility):

```
Task A: "makevn: unit tests + coverage"
  makevn clean verify-ut-coverage

Task B: "makevn: integration tests + coverage"
  makevn docker-up
  makevn docker-ps-required --wait-seconds 30
  makevn verify-it-coverage

# After both:
makevn coverage-changes
```

**Timeouts**: 120s for docker-up, 1800s for verify-ut, 3600s for verify-it.

**Troubleshooting**: If UT fails, check UT log. If IT fails, check IT log and Docker status. If both fail, prioritize the one with more tests.

## Success Criteria

The skill has been applied correctly if:

- user-owned Makefile/GNUmakefile content is preserved, with no dependence on their targets
- the user can run `makevn doctor`
- the selected mode matches the repo shape
- `makevn uninstall` cleanly removes the local integration
- the agent can use the installed `makevn` binary directly without inventing IDE-specific actions

### Strict Karate HTTP readiness

`makevn karate-all` requires a configured or detected application health URL
before starting Docker or packaging. Set `MAKEVN_APP_HEALTH_URL` in
`.makevn/config` when detection cannot identify the correct endpoint.
Resolution remains config, then persisted profile, then generic detection.

Only HTTP 2xx verifies readiness; redirects and other statuses are retried.
`MAKEVN_APP_HEALTH_TIMEOUT` defaults to 60 seconds and must be an integer
between 1 and 2147483647 (without leading zeros). Requests have a 2-second
connection limit and a 5-second total limit, capped by the remaining deadline.
Timeout or application exit prevents Karate from running and preserves the
application log under `.makevn/app/app.log`.

Standalone `run-app-bg` can still start without a health URL, but warns that
only process liveness was checked, not HTTP readiness. Use `karate-test`
directly for an externally managed application. HTTP readiness does not
validate JSON health status, application semantics, or Kafka availability.

### Doctor health configuration prompts

For an initialized runnable application without an explicit health URL,
interactive `makevn doctor` asks to confirm/correct a detected URL or enter
one when detection finds none. The input is prefilled with the detected URL or a suggested URL using the
application port/context and /health. Suggestions are explicitly unverified;
Enter confirms and saves the editable value, while typing skip leaves configuration
unchanged. Earlier compose
or LOCAL_CONTAINERS questions do not suppress the health question.

Nonempty input must use HTTP(S) without whitespace and is saved safely in
`.makevn/config`. Existing explicit URLs are preserved without prompting.
Without a terminal, doctor never requests input and reports how to configure
missing readiness. `profile refresh` remains automatic and noninteractive;
`init --force` does not force these prompts or overwrite existing config.

For `karate-all`, inspect `makevn doctor` for effective application Spring
profiles and their CI source. Selection precedence is `SPRING_PROFILES_ACTIVE`
(explicit empty is respected), `.makevn/config` `MAKEVN_KARATE_APP_PROFILES`,
then unambiguous literal Karate CI detection. No global `standalone,local`
default exists. Noninteractive execution does not prompt or write user config;
resolve ambiguous/dynamic candidates explicitly. The setting affects only the
managed Karate application, not the test JVM or standalone application commands.
