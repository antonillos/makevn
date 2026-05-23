# AI Agent Use

`makevn` ships a reusable skill under `skills/makevn/`.

The main idea is that a Java repository that already uses Maven should be operable from the terminal without IDE-specific knowledge. An agent should not need to understand IntelliJ buttons or editor run configurations if the repository can expose stable commands instead.

The intended product direction is that an agent should be able to use `makevn` as a normal installed binary, even without the skill. The skill should teach workflow policy and safety, not compensate for missing CLI behavior.

The skill is meant to teach agents to:

- inspect the repo before changing anything
- select the least invasive mode
- preserve compatibility with existing `Makefile` or `GNUmakefile`
- prefer `makevn uninstall` over heuristic cleanup
- operate the repository through terminal commands that also work from OpenCode and Codex
- treat `makevn` as the primary interface instead of relying on IDE actions
- prefer `--json` when it is available for the command being used
- avoid `--tail` unless a human explicitly requests an interactive local log view
- prefer compact runs so the agent sees plain summaries and short failure excerpts instead of colors, loaders, or full Maven logs
- use direct `makevn ...` subcommands by default instead of inventing bare
  root `make` targets

Agent-facing commands should be stable without requiring agents to inspect or execute
repository-owned helper scripts. For changed-code workflows, agents should call the
public commands directly:

- `makevn verify-changes`
- `makevn coverage`
- `makevn coverage-changes`

Those commands are intentionally backed by `makevn`'s installed `libexec/makevn/`
runtime, not by a target repository's legacy `scripts/make/*` folder. Legacy
Makefile scripts can be useful examples when improving parity, but they must not be
part of the agent execution contract.

## Exact Commands For Agents

Agents must use these command sequences exactly unless the human asks for a
different scope. Do not replace them with raw `mvn`, repository-local scripts,
or guessed root `make` targets.

Initial inspection:

```bash
makevn doctor
```

Initialize only when `doctor` reports missing, stale, or uninitialized makevn
state:

```bash
makevn init
makevn doctor
```

Changed-code verification without a full coverage gate:

```bash
makevn verify-changes
```

Changed-code coverage after a coverage-producing run:

```bash
makevn verify-changes
makevn coverage-changes
```

Unit-test coverage gate for repositories that do not need boot containers:

```bash
makevn clean verify-ut-coverage coverage-changes
```

Integration-test coverage gate for repositories that need boot containers:

```bash
makevn docker-up docker-ps-required --wait-seconds 30 clean verify-it-coverage coverage-changes
```

Latest aggregate coverage gate when a JaCoCo report already exists:

```bash
makevn coverage
```

Full confidence pass when coverage is not requested:

```bash
makevn clean verify
```

If `coverage` or `coverage-changes` fails with `JaCoCo report contains no
classes or execution data`, the repository did not produce coverage data. Do not
retry with raw Maven. First configure coverage activation in `.makevn/config`
when the repository workflow requires extra JaCoCo flags, then rerun the matching
coverage-producing command:

```bash
MAKEVN_COVERAGE_PROP_FLAGS="-Djacoco.skip=false -Damiga.jacoco"
```

After adding or changing coverage activation, refresh the profile and rerun the
gate:

```bash
makevn profile refresh
makevn clean verify-ut-coverage coverage-changes
```

Use the integration-test variant instead when the repository's coverage is based
on ITs or boot services:

```bash
makevn profile refresh
makevn docker-up docker-ps-required --wait-seconds 30 clean verify-it-coverage coverage-changes
```

MCP equivalents for OpenCode agents:

| CLI command | MCP tool |
| --- | --- |
| `makevn doctor` | `makevn_doctor` |
| `makevn init` | `makevn_init` |
| `makevn uninstall` | `makevn_uninstall` |
| `makevn profile refresh` | `makevn_profile_refresh` |
| `makevn make install` | `makevn_make_install` |
| `makevn make uninstall` | `makevn_make_uninstall` |
| `makevn validate` | `makevn_validate` |
| `makevn compile` | `makevn_compile` |
| `makevn test-compile` | `makevn_test_compile` |
| `makevn compile-tests` | `makevn_compile_tests` |
| `makevn package` | `makevn_package` |
| `makevn build` | `makevn_package` |
| `makevn clean` | `makevn_clean` |
| `makevn test` | `makevn_test` |
| `makevn verify-ut` | `makevn_verify_ut` |
| `makevn verify-ut-coverage` | `makevn_verify_ut_coverage` |
| `makevn verify-it` | `makevn_verify_it` |
| `makevn verify-it-coverage` | `makevn_verify_it_coverage` |
| `makevn verify` | `makevn_verify` |
| `makevn verify-changes` | `makevn_verify_changes` |
| `makevn pr-verify` | `makevn_pr_verify` |
| `makevn coverage` | `makevn_coverage` |
| `makevn coverage-changes` | `makevn_coverage_changes` |
| `makevn coverage --threshold PCT` | `makevn_coverage` with `threshold: PCT` |
| `makevn coverage-changes --threshold PCT --overall-threshold PCT` | `makevn_coverage_changes` with `threshold` and `overall-threshold` |
| `makevn format` | `makevn_format` |
| `makevn format --apply` | `makevn_format` with `apply: true` |
| `makevn checkstyle` | `makevn_checkstyle` |
| `makevn checkstyle --module MODULE --verbose` | `makevn_checkstyle` with `module` and `verbose: true` |
| `makevn docker-up` | `makevn_docker_up` |
| `makevn docker-down` | `makevn_docker_down` |
| `makevn docker-ps` | `makevn_docker_ps` |
| `makevn docker-stats` | `makevn_docker_stats` |
| `makevn docker-ps-required --wait-seconds 30` | `makevn_docker_ps_required` with `wait-seconds: 30` |
| `makevn docker-ps-required --compose karate` | `makevn_docker_ps_required` with `compose: karate` |
| `makevn karate-docker-up` | `makevn_karate_docker_up` |
| `makevn karate-docker-down` | `makevn_karate_docker_down` |
| `makevn karate-test` | `makevn_karate_test` |
| `makevn karate-test --tag TAG` | `makevn_karate_test` with `tag: TAG` |
| `makevn karate-all` | `makevn_karate_all` |
| `makevn karate-all --tag TAG` | `makevn_karate_all` with `tag: TAG` |
| `makevn run-app` | `makevn_run_app` |
| `makevn run-app-bg` | `makevn_run_app_bg` |
| `makevn stop-app` | `makevn_stop_app` |
| `makevn run` | `makevn_run` |
| `makevn exec -- COMMAND` | `makevn_exec` with `command: COMMAND` |
| `makevn jdk current` | `makevn_jdk_current` |
| `makevn jdk list` | `makevn_jdk_list` |

Karate workflows are optional. Agents should first use `makevn doctor` to confirm
that `Karate .tool-versions` and `Docker e2e compose file` are detected. When they
are present, use public commands such as:

- `makevn karate-test`
- `makevn karate-test --tag @smoke`
- `makevn karate-docker-up`
- `makevn karate-docker-down`
- `makevn karate-all`
- `makevn run-app-bg`
- `makevn stop-app`

Agents should not guess root targets such as `make karate-test`; those may exist in
some repositories, but they are not the portable `makevn` contract.

`makevn karate-docker-up` waits for the required services in the detected Karate
E2E compose to be running and healthy before returning. For a standalone service
validation, use `makevn docker-ps-required --compose karate`; plain
`makevn docker-ps-required` validates the boot compose. When services may still
be starting, agents should prefer `makevn docker-ps-required --wait-seconds N`
over inserting shell-level `sleep` calls between commands.

### Docker: Never use `makevn exec` for container operations

Agents must **never** use `makevn exec` to run raw `docker` or `docker compose`
commands. The `docker-*` and `karate-docker-*` subcommands are the only
supported interface for container lifecycle management:

- `makevn docker-up` — start all boot compose services
- `makevn docker-down` — stop all boot compose services
- `makevn docker-ps` — list all containers
- `makevn docker-stats` — show one-shot CPU and memory stats for all running containers
- `makevn docker-ps-required` — validate required services are healthy
- `makevn karate-docker-up` — start all Karate E2E compose services
- `makevn karate-docker-down` — stop all Karate E2E compose services

`makevn docker-up` runs a full lifecycle: `down -v --remove-orphans`,
`volume prune -f`, then `up --detach` for **all** services. It does not
support targeting a single service. If only one service needs to be started
(such as `schema_registry` for local development without the full stack),
use `makevn docker-up` to start everything — the lifecycle guarantees a clean
state regardless. Do not fall back to `docker compose up -d <service>` or
`makevn exec -- docker compose ...`; those bypass `makevn`'s compose file
resolution, override detection, and logging.

Karate tests need the real application running. For a manual chain, agents should
use `makevn run-app-bg` before `makevn karate-test` and always finish with
`makevn stop-app`. For the full flow, `makevn karate-all` owns that lifecycle.

The optional make integration exposes namespaced `vn-*` targets only. Agents should
run public Docker CLI commands as `makevn docker-up`, `makevn docker-down`,
`makevn docker-ps`, `makevn docker-stats`, or `makevn docker-ps-required`, not as bare root targets
such as `make docker-up` or `make docker-ps-required`. Use
`make -f .makevn/makevn.mk vn-docker-*` or `vn-karate-*` only when explicitly validating make
integration.

## Generic Workflow

1. Load the `makevn` skill in the agent environment.
2. Run `makevn doctor` in the target repo.
3. If the repo is not initialized and the user wants installation, run `makevn init`.
4. Use `makevn make install` only when the user explicitly wants Make integration.
5. Validate the result.
6. Use `makevn uninstall` to revert.

When JSON output exists for the command being used, agents should prefer it over parsing prose.

Today that guidance is forward-looking: public `--json` behavior is still part of the Rust transition rather than the currently published CLI surface.

## OpenCode Workflow

The project ships a `.mcp.json` at the root that configures the dedicated
`makevn-mcp` Rust MCP server. OpenCode loads it automatically — no manual setup
needed once `makevn-mcp` is installed and available in `PATH`.

When the MCP server is active, the agent can call makevn commands as MCP tools
(e.g. `doctor`, `test`, `verify`) in addition to running them via the CLI.
MCP tools invoke the installed sibling `makevn` binary with compact,
agent-safe output.

Inside OpenCode, the intended flow is:

1. inspect the repository shape
2. run `makevn doctor` or use the `doctor` MCP tool
3. initialize only if needed
4. prefer `makevn ... --json` when machine-readable output is available and helps with decision making
5. run `makevn build`, `makevn test`, `makevn verify`, or `makevn exec -- ...`
6. avoid IDE-specific instructions unless the user explicitly asks for them

When using the MCP tools directly, use the explicit `makevn_*` tool names and
follow this runbook for changed-code verification:

1. `makevn_doctor` on the target repository.
2. `makevn_init` if doctor reports missing, stale, or uninitialized makevn state.
3. `makevn_verify_changes` for changed modules or changed tests.
4. `makevn_coverage_changes` after a coverage-producing run.
5. Report the makevn failure excerpt or gate result directly.

Agents should not second-guess this sequence by switching to raw `mvn`, adding
manual `-pl` or `-am` flags, or invoking repository-local helper scripts. Module
selection, reactor dependencies, Maven base paths, and coverage report paths are
part of the `makevn verify-changes` and `makevn coverage-changes` contract.

Important MCP tool mappings:

- Use the exact MCP mapping table in `Exact Commands For Agents`.
- Do not infer tool names from CLI names when a tool schema is visible; use the
  explicit `makevn_*` tool name and its typed parameters.

If a documented MCP tool is missing from the visible schema, the client is likely
using a stale MCP session or a different server command. Restart or reload the
agent session and confirm the configured command is `makevn-mcp`.

For pull-request or task-final verification, agents should prefer the smallest
command that proves the touched surface:

- changed modules/tests: `makevn verify-changes`
- changed-code coverage after a coverage-producing run: `makevn coverage-changes`
- latest aggregate coverage gate: `makevn coverage`
- full confidence pass: `makevn verify`

Because agent frameworks differ, this repository ships the skill contents and examples rather than hardcoding a single agent-specific installation path.

## Robustness Sweep

Use `test/repo-sweep/run.sh` when validating makevn against local real-world
repositories rather than synthetic smoke fixtures.

```bash
test/repo-sweep/run.sh /Users/antonio.saco/Projects/github
test/repo-sweep/run.sh /Users/antonio.saco/Projects/github/Iced-Latte
```

The sweep follows the OpenCode/MCP contract directly: it starts `makevn-mcp`, calls
tools through JSON-RPC, installs makevn into a temporary prefix, and clones each
target repository before running mutating commands such as `init`, `make install`,
`clean`, or `uninstall`. Repository failures are reported as product signal, not
as instructions to modify the fixture repositories.

Set `MAKEVN_REPO_SWEEP_TIMEOUT_SECONDS` to keep exploratory runs bounded:

```bash
MAKEVN_REPO_SWEEP_TIMEOUT_SECONDS=60 test/repo-sweep/run.sh /path/to/repos
```

## Codex Workflow

Inside Codex, the intended flow is the same terminal contract:

1. load or follow `skills/makevn/SKILL.md`
2. inspect the repository shape before changing files
3. run `makevn doctor`
4. use `makevn init`, `makevn uninstall`, and verification commands instead of editing `.makevn/` by hand
5. prefer the smallest proving command: `makevn test --name ...`, `makevn coverage`, `makevn verify-changes`, `makevn coverage-changes`, or `makevn verify`
6. avoid IDE-specific instructions unless the user explicitly asks for them

Codex-specific repo work should still use normal engineering hygiene: keep edits scoped, verify with concrete commands, and leave the installed `libexec/makevn/` runtime as the source of behavior instead of calling target-repository helper scripts.

See also:

- `docs/cli-contract.md`
- `docs/backend-contract.md`
