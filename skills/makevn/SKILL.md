---
name: makevn
description: >-
  Terminal contract for Java/Maven work. Use this skill whenever working in any
  Java/Maven repository: running builds, tests, or verifications. Run makevn
  doctor first, avoid IDE-specific instructions, and verify changes with makevn
  test, makevn verify-ut, makevn verify-it, or makevn verify as appropriate.
---

# makevn Skill

Use this skill when the user wants to standardize local Java Maven workflows, resolve JDK context automatically, integrate with `make` safely, or add/remove `makevn` from a repository.

## What `makevn` Is

`makevn` is a terminal-first CLI for Java Maven repositories.

Its core premise is that if a repository already uses Maven, local build and test workflows should not require IDE-specific execution knowledge. The agent should be able to operate the repository from the terminal by applying the correct Java context.

The intended product direction is that `makevn` should be usable by agents as a normal installed binary. The skill should improve decision making and safety, not act as a required runtime layer.

It provides:

- repository inspection with `makevn doctor`
- safe initialization with `makevn init`
- transparent cleanup with `makevn uninstall`
- context-aware command execution using JDK resolution from `.tool-versions`
- optional `make` integration through namespaced `vn-*` targets
- a path toward structured `--json` output across the public command surface

## Safety Rules

1. Always determine the repository root before running any `makevn` command. `makevn` must be executed from the repo root, never from a subdirectory or module. Locate the root by finding the `.git` directory.
2. Run `makevn doctor` before recommending `init`. If `.makevn/` already exists in the repo root, the repo is already initialized — skip `init` unless the user explicitly asks to reinitialize. If `doctor` reports that the repository is not initialized, run `makevn init` before continuing with adoption or verification work.
3. Never overwrite an existing `Makefile` or `GNUmakefile`.
4. Prefer `makevn init` as the default adoption path.
5. Use `makevn make install` only when the user explicitly wants `make` support.
6. Let `makevn make install` choose whether to update one existing makefile or create a minimal root `Makefile`.
7. Prefer `makevn uninstall` over manual cleanup.
8. Do not edit makefiles manually when `makevn make install` or `makevn make uninstall` owns that behavior.
9. Prefer `--json` when the command supports structured output and the agent needs reliable machine-readable data.
10. Avoid `--tail` unless the human explicitly asked for an interactive local log view. Use `--compact` for agent-facing runs when invoking the CLI directly; MCP tools already use compact output.
11. Treat `makevn` subcommands as the primary public interface. Do not translate them into bare `make` targets. For Docker commands, run `makevn docker-up`, `makevn docker-down`, `makevn docker-ps`, `makevn docker-stats`, or `makevn docker-ps-required`; do not run bare targets such as `make docker-up` or `make docker-ps-required`.
12. Treat Karate workflows the same way: run `makevn karate-docker-up`, `makevn karate-docker-down`, `makevn karate-test`, or `makevn karate-all` only when `makevn doctor` detects Karate files. Do not assume every repository has Karate.
13. Karate tests need the real app running. Use `makevn run-app-bg` before `makevn karate-test`, and always finish with `makevn stop-app`; `makevn karate-all` owns that lifecycle for the full flow.
14. Do not assume every repository uses `LOCAL_CONTAINERS`. Let `makevn doctor`, `.makevn/config`, the repository profile, or the user's exported `LOCAL_CONTAINERS` decide that behavior.
15. Do not assume a repository needs Docker for `verify` just because it has a `docker-compose.yml`. Treat Docker as a verification prerequisite only when `makevn doctor`, `.makevn/config`, a persisted profile, or a test compose under `src/test/resources/compose` says so.
16. Do not hardcode company-specific application health URLs, path prefixes, package names, or repository paths. Let `makevn doctor` detect the health URL, or set `MAKEVN_APP_HEALTH_URL` in `.makevn/config` when the repository needs an explicit override.
17. Do not invent formatter or Checkstyle goals. Use `makevn format` and `makevn checkstyle` only when the repo declares a supported plugin or `.makevn/config` sets `MAKEVN_FORMAT_CHECK_GOAL`, `MAKEVN_FORMAT_APPLY_GOAL`, or `MAKEVN_CHECKSTYLE_GOAL`.

## Failure Triage For Agents

Use this triage before deciding whether to edit repository code, change makevn, or report an environment issue:

- Missing JDK, Maven, Docker, or local executable: report an environment issue. Do not bypass makevn with raw `JAVA_HOME=... mvn`; first use `makevn doctor`, `makevn jdk list`, or ask the human to install/configure the missing prerequisite.
- Unsupported formatter, Checkstyle, PIT, coverage, Docker compose, or Karate capability: skip that command. Do not invent Maven goals, compose files, or repository scripts.
- `makevn docker-ps-required`: use it after `makevn docker-up`, or when `doctor`/the human says the required services are already running. Do not treat missing containers as a makevn bug.
- `makevn verify` / `makevn verify-it`: let makevn decide whether Docker preflight is required. If the command reaches Maven without starting Docker, do not add Docker commands manually unless `doctor`, `.makevn/config`, or the human confirms boot services are required.
- Karate tests: use `makevn karate-all` for the owned lifecycle, or use `makevn run-app-bg`, `makevn karate-test`, and `makevn stop-app` as a manual chain. Do not run `karate-test` against a stopped app.
- Coverage gates: run `makevn coverage-changes` only after a coverage-producing verification run. If JaCoCo data is missing or empty, configure coverage activation and rerun the matching `verify-*-coverage` flow instead of switching to raw Maven.
- Parser errors, unknown makevn commands, MCP option-ordering failures, or makevn usage errors for documented commands are makevn product bugs. Investigate makevn rather than editing the target repository.
- Repository test/build failures after makevn reached Maven are repository failures. Report the failing command and log path; do not edit fixture repositories unless the human asks.

## When A Command Counts As OK

Apply a Karpathy-style verification rule: do not treat a command as successful just because it printed plausible output or because the agent expected it to work.

A command is only OK when all of these are true:

1. the process exited with code `0`
2. the command reached the user-facing goal that was requested
3. there is a concrete verification signal, not just agent interpretation

Preferred verification signals:

- `makevn doctor`: the repo is recognized correctly and the reported initialization and Make integration status match the repo shape
- `makevn init`: the expected files were created or updated, and a follow-up `makevn doctor` or `vn-doctor` confirms the integration works
- `makevn make install`: `.makevn/makevn.mk` exists and a follow-up `make` command or `makevn doctor` confirms the integration works
- `makevn make uninstall`: the managed Make integration is gone while `.makevn/` still exists
- `makevn uninstall`: the managed assets are gone, and a follow-up check confirms cleanup
- `makevn build`, `makevn test`, `makevn verify`: the command exits `0` and no follow-up evidence contradicts the requested outcome
- selected workflow changes: rerun the smallest relevant validating command instead of assuming success from the edit alone

If the command exits `0` but the requested outcome is still not verified, do not report success yet. State what remains unverified and run the smallest reasonable check.

## Agent Workflow

1. **Determine the repo root first.** Find the directory that contains `.git/`. All `makevn` commands must run from this directory — never from a module subdirectory.
2. Inspect the repo root for:
   - `pom.xml`
   - `.tool-versions`
   - `Makefile`
   - `GNUmakefile`
   - `.makevn/` — if this directory exists, the repo is **already initialized**; do not run `makevn init` unless explicitly requested
3. Run `makevn doctor`.
4. If `makevn doctor` reports that the repo is not initialized, run `makevn init` before continuing with adoption or verification work.
5. If the user explicitly wants Make integration, run `makevn make install`.
6. Validate the result with:
    - `makevn doctor`
    - or `make -f .makevn/makevn.mk vn-doctor`
7. If the user wants rollback, run `makevn uninstall`.

In OpenCode and Codex specifically, the agent should treat `makevn` as the terminal contract for the repository. It does not need to invent IDE run configurations or rely on editor-specific behavior. When structured output exists, prefer `--json` over parsing prose.

For Codex, keep changes surgical: inspect the repo first, run the smallest `makevn` command that proves the touched behavior, and do not edit `.makevn/` state manually when `makevn init`, `profile refresh`, or `uninstall` owns that behavior.

## Adoption Model

Default:

- `makevn init`

Optional when the user wants `make`:

- `makevn make install`

## Using `makevn exec` with Subdirectory Maven Projects

Some repositories keep the Maven project inside a subdirectory (e.g., `code/`) rather than at the repo root. `makevn doctor` reports this as `Maven base path`.

This only matters when falling back to `makevn exec -- mvn`. First-class commands (`makevn test`, `makevn verify`, `makevn package`, etc.) resolve the Maven base path internally — do not add `-f` to them and do not mention the base path in your reasoning when using these commands.

**Only check `Maven base path` in the `makevn doctor` output when composing a `makevn exec -- mvn ...` command.**

- If `Maven base path` equals the repo root → no `-f` flag needed.
- If `Maven base path` is a subdirectory (e.g., `.../repo/code`) → you **must** add `-f <relative-path>/pom.xml` to every `mvn` invocation, where `<relative-path>` is the subdirectory relative to the repo root.

Example: `makevn doctor` reports `Maven base path: /project/root/code`

```bash
# Wrong — Maven cannot find the reactor from the repo root
makevn exec -- mvn -pl application test

# Correct
makevn exec -- mvn -f code/pom.xml -pl application test
```

`makevn exec` always runs from the repo root, so the `-f` flag is the only safe way to point Maven at the correct `pom.xml` when the project lives in a subdirectory.

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
makevn make install
makevn make uninstall
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
makevn exec -- mvn -v
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

1. Run `makevn doctor` first.
2. Run `makevn init` when doctor says the repository is not initialized, stale,
   or missing local makevn state.
3. Run `makevn verify-changes` for changed modules or changed tests.
4. Run `makevn coverage-changes` after a coverage-producing verification run.
5. Treat a coverage gate failure as the result to report, not as a reason to
   invent raw Maven commands.

Exact coverage commands for agents:

```bash
# Changed-code coverage when verify-changes generated coverage data
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

**Always prefer `makevn test --name` over `makevn exec -- mvn -Dtest=...`** when the goal is to run one or more specific test classes. This works for any test type — unit tests (UT) and integration tests (IT) alike.

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

Only fall back to `makevn exec -- mvn` when you need Maven flags or options that `makevn test` does not expose (e.g., `-pl` to target a specific module, or additional `-D` properties). In that case, check `Maven base path` in `makevn doctor` output first and add `-f <path>/pom.xml` if the Maven root is a subdirectory.

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

### Never use `makevn exec` for Docker operations

`makevn exec` is for Maven commands, not for containers. Agents must **never**
use `makevn exec` to run raw `docker` or `docker compose` commands — even if the
command appears correct. Always use the dedicated `docker-*` and `karate-docker-*`
subcommands. This guarantees that compose file paths, override files, Docker
binary resolution, and log handling are all applied consistently.

`makevn docker-up` runs a full lifecycle: `down -v --remove-orphans`,
`volume prune -f`, then `up --detach` for **all** boot compose services.
There is no option to target a single service. If only one service needs
starting, run `makevn docker-up` anyway — the
lifecycle ensures a clean state and unused services remain idle. Do not
fall back to raw docker commands or `makevn exec -- docker compose ...`.

Do not guess a root `make` target from a `makevn` subcommand name. This is invalid unless the repository itself defines such a target:

```bash
# Wrong
make docker-up
make docker-down
make docker-ps
make docker-stats
make docker-ps-required
```

The optional make integration only exposes namespaced `vn-*` targets. Use these only when the user explicitly wants to exercise the make integration. If the repo `Makefile` includes `.makevn/makevn.mk`, call them directly:

```bash
make vn-docker-up
make vn-docker-down
make vn-docker-ps
make vn-docker-stats
make vn-docker-ps-required
make vn-karate-test
make vn-run-app-bg
make vn-stop-app
```

Some targets accept Make variables instead of flags:

```bash
make vn-test NAME=MyTest
make vn-test NAMES="MyTest,OtherTest"
make vn-test NAME=MyTest FAST=true
make vn-karate-test TAG=@smoke
make vn-exec MAKEVN_ARGS="-- mvn -v"
make vn-docker-ps-required MAKEVN_DOCKER_PS_REQUIRED_ARGS="--compose karate"
```

## Make Integration

`makevn make install` generates `.makevn/makevn.mk` and a root `Makefile` that includes it. All `vn-*` targets delegate to the installed `makevn` binary — they are thin wrappers, not an alternative implementation.

Available targets mirror the `makevn` command surface: `vn-doctor`, `vn-init`, `vn-make-install`, `vn-make-uninstall`, `vn-uninstall`, `vn-profile-refresh`, `vn-compile`, `vn-test-compile`, `vn-compile-tests`, `vn-validate`, `vn-package`, `vn-build`, `vn-clean`, `vn-test`, `vn-verify-ut`, `vn-verify-ut-coverage`, `vn-verify-it`, `vn-verify-it-coverage`, `vn-verify`, `vn-verify-changes`, `vn-coverage-changes`, `vn-pr-verify`, `vn-docker-up`, `vn-docker-down`, `vn-docker-ps`, `vn-docker-stats`, `vn-docker-ps-required`, `vn-karate-docker-up`, `vn-karate-docker-down`, `vn-karate-test`, `vn-karate-all`, `vn-run-app`, `vn-run-app-bg`, `vn-stop-app`, `vn-run`, `vn-jdk-current`, `vn-jdk-list`, `vn-exec`.

## Subagent Workflows

These workflows use the agent framework's subagent mechanism (e.g., OpenCode Task tool). Each subagent appears as an independent card in the TUI with its description as the title, and each `makevn` command within the subagent is visible as an individual tool call.

### Naming convention

Use descriptive descriptions that identify both the action and the scope:

- `"makevn: boot verify + coverage"`
- `"makevn: multi-test runner"`
- `"makevn: adaptive test"`
- `"makevn: karate E2E lifecycle"`
- `"makevn: changes verification"`
- `"makevn: parallel verify"`

**Importante**: OpenCode muestra las primeras palabras del **prompt** como título en el TUI, no el parámetro `description`. Para que el TUI muestre un título identificable, el prompt debe empezar con el nombre del workflow:

```
Task(description="makevn: boot verify + coverage", prompt="
  makevn: boot verify + coverage
  
  Ejecutar secuencia:
  1. makevn docker-up
  ...
")
```

Así el TUI mostrará "makevn: boot verify + coverage" como título del subagente.

### Timeout handling

Los subagentes pueden fallar por timeout cuando ejecutan comandos largos. Tiempos de referencia:

| Comando | Timeout típico | Notas |
|---|---|---|
| `docker-up` | 60-120s | Depende de imágenes locales vs pull |
| `docker-ps-required --wait-seconds 30` | 30-60s | Espera explícita + health checks |
| `compile` | 60-180s | Depende del tamaño del proyecto |
| `verify-ut` | 120-600s | Depende de número de tests |
| `verify-it` | 300-1800s | Tests de integración suelen ser lentos |
| `verify` | 600-3600s | UT + IT combinados |
| `karate-test` | 120-600s | Depende de escenarios E2E |
| `coverage-changes` | 30-120s | Análisis de JaCoCo |

**Si un subagente falla por timeout**:

1. **Identificar el paso que colgó**: Revisar el log en `.makevn/logs/<command>-*.log`
2. **Reintentar con timeout mayor**: Si el comando lo soporta, usar `--timeout-seconds` (ej: `makevn exec --timeout-seconds 300 -- mvn verify`)
3. **Dividir el workflow**: Si `verify` es muy largo, separar en `verify-ut` + `verify-it` con subagentes paralelos
4. **Cancelar servicios colgados**: Si `docker-up` se cuelga, ejecutar `makevn docker-down` y reintentar

**Comportamiento del subagente ante timeout**:

- El subagente detecta el timeout y retorna error inmediatamente
- No ejecuta los pasos siguientes (fail-fast)
- Reporta qué paso falló y el log path
- El agente principal puede decidir reintentar o reportar al usuario

**Ejemplo de manejo en el agente principal**:

```
Task(description="makevn: boot verify + coverage", prompt="
  Ejecutar secuencia:
  1. makevn docker-up (timeout: 120s)
  2. makevn docker-ps-required --wait-seconds 30
  3. makevn clean compile verify (timeout: 1800s)
  4. makevn coverage-changes
  
  Si algún paso falla por timeout:
  - Reportar qué paso falló
  - Incluir log path: .makevn/logs/<command>-*.log
  - No reintentar automáticamente
  - Esperar instrucciones del usuario
")
```

### `boot-verify-coverage` — Boot containers + full verify + coverage gate

**Visibilidad TUI**: `"makevn: boot verify + coverage"`

**Cuándo usar**:
- Repos con Docker boot services + coverage gate
- Validación completa antes de PR
- Sustituye a la secuencia manual `docker-up docker-ps-required clean compile verify coverage-changes`

**Prompt del subagente**:

```
makevn: boot verify + coverage

Ejecutar secuencia:
1. makevn docker-up (timeout: 120s)
2. makevn docker-ps-required --wait-seconds 30
3. makevn clean compile verify (timeout: 1800s)
4. makevn coverage-changes (timeout: 120s)

Si algún paso falla:
- Reportar qué paso falló
- Incluir log path: .makevn/logs/<command>-*.log
- No reintentar automáticamente
```

**Secuencia**:

```bash
makevn docker-up                    # timeout: 120s
makevn docker-ps-required --wait-seconds 30
makevn clean compile verify         # timeout: 1800s
makevn coverage-changes             # timeout: 120s
```

**Comportamiento**: fail-fast — si cualquier paso falla, el subagente retorna error y no ejecuta los siguientes.

**Timeouts**: El subagente debe abortar si `docker-up` tarda más de 120s o `verify` tarda más de 1800s. Si `docker-ps-required` no pasa en 30s, reportar servicios no saludables.

**Resultado**:

```json
{
  "steps": 4,
  "passed": true,
  "failed_step": null,
  "docker_healthy": true,
  "verify_exit_code": 0,
  "coverage_passed": true
}
```

**Troubleshooting**: Si `verify` falla, revisar el log en `.makevn/logs/verify-*.log`. Si `coverage-changes` reporta "JaCoCo report contains no classes", configurar flags de cobertura y repetir. Si `docker-up` se cuelga, ejecutar `makevn docker-down` y reintentar.

### `multi-test-runner` — Multiple tests with consolidated results

**Visibilidad TUI**: `"makevn: multi-test runner"`

**Cuándo usar**:
- Varias clases de test que no pertenecen al mismo módulo Maven
- Necesitas un reporte consolidado de qué pasó y qué falló
- Quieres coverage automático si todos pasan

**Prompt del subagente**:

```
makevn: multi-test runner

Recibida lista de tests: [AuthTest, PaymentTest, NotificationTest]

Ejecutar:
1. makevn doctor --compact
2. Para cada test: makevn test --name <Test> (timeout: 300s por test)
3. Si todos pasan: makevn coverage-changes

Reportar:
- Tests que pasaron
- Tests que fallaron
- Log paths de cada test
```

**Secuencia**:

```bash
makevn doctor --compact
makevn test --name AuthTest
makevn test --name PaymentTest
makevn test --name NotificationTest
# Si todos pasan:
makevn coverage-changes
```

**Comportamiento**: El subagente recibe una lista de test names, ejecuta `makevn test --name` por cada uno. Cada test es una tool call individual en el TUI. Si todos pasan, ejecuta coverage-changes automáticamente.

**Timeouts**: 300s por test individual. Si un test tarda más, abortar ese test y continuar con los siguientes.

**Resultado**:

```json
{
  "total": 3,
  "passed": 2,
  "failed": ["NotificationTest"],
  "coverage_passed": false,
  "logs": [
    "AuthTest: .makevn/logs/test-AuthTest-*.log",
    "PaymentTest: .makevn/logs/test-PaymentTest-*.log",
    "NotificationTest: .makevn/logs/test-NotificationTest-*.log"
  ]
}
```

**Troubleshooting**: Si un test falla, revisar su log individual. Si coverage-changes falla, verificar que los tests generaron datos JaCoCo.

### `adaptive-test` — Auto-detect UT/IT and run appropriate command

**Visibilidad TUI**: `"makevn: adaptive test"`

**Cuándo usar**:
- Modificaste un test y quieres ejecutarlo correctamente
- No sabes si es UT o IT
- No sabes si cambió solo el test o también el código

**Prompt del subagente**:

```
makevn: adaptive test

Archivos modificados: [AuthServiceTest.java, PaymentService.java]

Analizar:
1. git diff --name-only HEAD~1
2. Clasificar cada test (UT/IT por convención de path)
3. Detectar si cambió código de producción (src/main/java)

Ejecutar según matriz:
| Test type | Scope | Comando |
|-----------|-------|--------|
| UT | solo test | makevn test --fast --name <Test> |
| UT | test+code | makevn test --name <Test> |
| IT | solo test | makevn docker-up → docker-ps-required → test --name <Test> |
| IT | test+code | makevn docker-up → docker-ps-required → test --name <Test> |

Reportar resultado consolidado.
```

**Secuencia**:

```bash
# El subagente analiza los archivos modificados:
git diff --name-only HEAD~1

# Clasifica cada test:
# - */src/test/java/**/*IT.java → IT
# - */src/test/java/**/*Test.java → UT
# - */src/it/** → IT

# Detecta alcance:
# - ¿Cambió src/main/java/? → test+code
# - ¿Solo cambió el test? → solo test

# Ejecuta según la matriz:
# | Test type | Scope | Comando |
# |-----------|-------|--------|
# | UT | solo test | makevn test --fast --name <Test> |
# | UT | test+code | makevn test --name <Test> |
# | IT | solo test | makevn docker-up → docker-ps-required → test --name <Test> |
# | IT | test+code | makevn docker-up → docker-ps-required → test --name <Test> |
```

**Comportamiento**: El subagente recibe los archivos modificados (o un test name explícito), clasifica cada uno, detecta si cambió código de producción, y ejecuta el comando correcto. Si hay múltiples tests del mismo tipo y scope, los combina en un solo `test --name A,B,C`.

**Timeouts**: 120s para docker-up, 30s para docker-ps-required, 300s por test.

**Resultado**:

```json
{
  "tests": [
    {
      "name": "AuthServiceTest",
      "type": "UT",
      "scope": "test+code",
      "command": "makevn test --name AuthServiceTest",
      "passed": true,
      "log": ".makevn/logs/test-AuthServiceTest-*.log"
    }
  ],
  "all_passed": true,
  "coverage_passed": true
}
```

**Troubleshooting**: Si el subagente no puede clasificar un test (convención no estándar), preguntar al usuario. Si Docker no está disponible para IT, reportar error.

### `karate-runner` — Full Karate E2E lifecycle

**Visibilidad TUI**: `"makevn: karate E2E lifecycle"`

**Cuándo usar**:
- Repos con Karate E2E tests
- Necesitas el ciclo completo: Docker + app + tests + cleanup
- Sustituye a `makevn karate-all` manual

**Prompt del subagente**:

```
makevn: karate E2E lifecycle

Ejecutar ciclo completo:
1. makevn karate-docker-up (timeout: 120s)
2. makevn docker-ps-required --compose karate --wait-seconds 30
3. makevn package (timeout: 300s)
4. makevn run-app-bg (timeout: 60s para health check)
5. makevn karate-test --tag @smoke (timeout: 600s)
6. makevn stop-app
7. makevn karate-docker-down

Si karate-test falla, ejecutar stop-app y karate-docker-down antes de retornar error.
Reportar log path: .makevn/logs/karate-test-*.log
```

**Secuencia**:

```bash
makevn karate-docker-up
makevn docker-ps-required --compose karate --wait-seconds 30
makevn package
makevn run-app-bg
makevn karate-test --tag @smoke  # opcional
makevn stop-app
makevn karate-docker-down
```

**Comportamiento**: El subagente ejecuta el ciclo completo. Si `karate-test` falla, el subagente aún ejecuta `stop-app` y `karate-docker-down` antes de retornar error.

**Timeouts**: 120s para docker-up, 60s para run-app-bg health check, 600s para karate-test.

**Resultado**:

```json
{
  "docker_healthy": true,
  "app_started": true,
  "tests_passed": true,
  "tests_failed": 0,
  "cleanup_completed": true,
  "log": ".makevn/logs/karate-test-*.log"
}
```

**Troubleshooting**: Si `run-app-bg` falla, revisar `.makevn/app/app.log`. Si `karate-test` falla, revisar `.makevn/logs/karate-test-*.log`.

### `changes-validator` — Git diff + verify + coverage (PR review)

**Visibilidad TUI**: `"makevn: changes verification"`

**Cuándo usar**:
- **Revisar todos los cambios de una PR** (workflow más común)
- Validar cambios antes de commit/PR
- Necesitas verificar solo los módulos afectados
- Quieres coverage de los cambios
- El usuario dice "revisa los cambios de la PR" o "verifica los cambios actuales"

**Prompt del subagente**:

```
makevn: changes verification

Contexto: Revisión de cambios de PR / working tree

Ejecutar:
1. makevn doctor --compact
2. Si doctor detecta Docker compose file o LOCAL_CONTAINERS:
   - makevn docker-up (timeout: 120s)
   - makevn docker-ps-required --wait-seconds 30
3. makevn clean (opcional, si hay dudas de estado previo)
4. makevn verify-changes (timeout: 1800s)
5. makevn coverage-changes (timeout: 120s)

Si verify-changes falla, no ejecutar coverage-changes.
Reportar módulos afectados, tests rotos y resultado de coverage.
```

**Secuencia completa**:

```bash
makevn doctor --compact
# Si doctor detecta Docker necesario:
makevn docker-up
makevn docker-ps-required --wait-seconds 30
makevn clean                          # opcional, si estado previo es incierto
makevn verify-changes
makevn coverage-changes
```

**Comportamiento**: El subagente ejecuta `doctor` primero para detectar si Docker es necesario. Si el repo tiene `Docker compose file`, `LOCAL_CONTAINERS`, o tests bajo `src/test/resources/compose`, arranca los servicios antes de `verify-changes`. Luego ejecuta `verify-changes` (que detecta automáticamente qué módulos cambiaron) y `coverage-changes`. Si `verify-changes` falla, no ejecuta coverage.

**Cuándo usar `clean`**:
- Si hay builds previos que pueden contaminar resultados
- Si el usuario reporta resultados inconsistentes
- Si es la primera verificación después de un rebase/merge
- Por defecto: omitir `clean` para ahorrar tiempo (makevn usa caché)

**Timeouts**: 120s para docker-up, 30s para docker-ps-required, 1800s para verify-changes, 120s para coverage-changes.

**Resultado**:

```json
{
  "docker_started": true,
  "modules_changed": ["domain", "application"],
  "tests_passed": 42,
  "tests_failed": 0,
  "coverage_passed": true,
  "log": ".makevn/logs/verify-changes-*.log"
}
```

**Troubleshooting**: Si `verify-changes` no detecta cambios, verificar que hay commits en la rama. Si `coverage-changes` falla, verificar que JaCoCo está configurado. Si los tests fallan inconsistentemente, reintentar con `clean` primero. Si Docker falla, revisar `makevn docker-ps` para ver estado de servicios.

### `parallel-verify` — UT and IT in parallel

**Visibilidad TUI**: `"makevn: unit tests + coverage"` + `"makevn: integration tests + coverage"`

**Cuándo usar**:
- Repos donde UT e IT son independientes
- Quieres ejecutar ambos en paralelo para ahorrar tiempo
- El perfil del repo lo permite (detectado por `makevn doctor`)

**Prompt del subagente A (UT)**:

```
makevn: unit tests + coverage

Ejecutar:
1. makevn clean verify-ut-coverage (timeout: 1800s)

Reportar exit code y log path.
```

**Prompt del subagente B (IT)**:

```
makevn: integration tests + coverage

Ejecutar:
1. makevn docker-up (timeout: 120s)
2. makevn docker-ps-required --wait-seconds 30
3. makevn verify-it-coverage (timeout: 3600s)

Reportar exit code y log path.
```

**Secuencia**:

```bash
# Subagente A (UT):
makevn clean verify-ut-coverage

# Subagente B (IT) - en paralelo:
makevn docker-up
makevn docker-ps-required --wait-seconds 30
makevn verify-it-coverage

# Después de esperar ambos:
makevn coverage-changes
```

**Comportamiento**: El agente principal lanza dos subagentes concurrentes. Espera a que ambos terminen. Si ambos pasan, ejecuta `coverage-changes`.

**Timeouts**: 120s para docker-up, 1800s para verify-ut, 3600s para verify-it.

**Resultado**:

```json
{
  "ut_passed": true,
  "it_passed": true,
  "coverage_passed": true,
  "ut_log": ".makevn/logs/verify-ut-*.log",
  "it_log": ".makevn/logs/verify-it-*.log"
}
```

**Troubleshooting**: Si UT falla, revisar log UT. Si IT falla, revisar log IT y estado de Docker. Si ambos fallan, priorizar el que tenga más tests.

## Success Criteria

The skill has been applied correctly if:

- the repo keeps any existing `Makefile` or `GNUmakefile` compatible
- the user can run `makevn doctor`
- the selected mode matches the repo shape
- `makevn uninstall` cleanly removes the local integration
- the agent can use the installed `makevn` binary directly without inventing IDE-specific actions
