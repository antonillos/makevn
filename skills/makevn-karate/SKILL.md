---
name: makevn-karate
description: >-
  Use for MakeVN Karate E2E, managed application lifecycle, external applications, Spring profiles, health readiness and E2E failure diagnosis.
---

# MakeVN Karate

Load [makevn](../makevn/SKILL.md) first if not already read; finish doctor/setup.
Read [application and E2E details](references/workflows.md) before execution.
Confirm Karate and E2E capabilities in doctor; do not assume every repository has them.
Load [makevn-docker](../makevn-docker/SKILL.md) when containers are required, including
authorization for the startup invoked by `karate-all`. Its container startup
preserves volumes; deleting E2E data requires an explicitly authorized
`karate_docker_reset` operation.

| Intent | CLI | MCP | Evidence |
| --- | --- | --- | --- |
| Managed application + E2E | `makevn karate-all --tag @smoke` | `karate_all` with `tag` | Required services ready, HTTP health ready, Karate results, application cleanup |
| Existing external application | `makevn karate-test --tag @smoke` | `karate_test` with `tag` | Target application confirmed and requested Karate tests ran |
| Manual managed application | `makevn run-app-bg`, then `makevn karate-test`, finally `makevn stop-app` | `run_app_bg`, `karate_test`, `stop_app` | Stop after any prerequisite failure; perform application cleanup even on test failure |

`karate-all` owns application cleanup; do not assume it tears down containers.
Container teardown is a separate authorized operation. Do not stop an externally
managed application. Standalone process liveness is not HTTP readiness, and HTTP
readiness does not prove application semantics, JSON health status or Kafka readiness.

If a container prerequisite fails, inspect the returned diagnostics and follow the
[Docker prerequisite decision table](../makevn-docker/references/workflows.md#docker-prerequisite).
For a failed or partial Karate stack, when diagnosis justifies recovery and stopping
the selected project is authorized, use volume-preserving `karate_docker_down`,
then `karate_docker_up`, then `docker_ps_required` with `compose: "karate"` and an
appropriate wait. Resume the original scenario only after readiness succeeds.
Reset deletes the project's volume data and requires separate explicit authorization.

### Disabling Compose discovery

Compose answers also accept an absolute path to an existing file outside the
detected candidates (CLI option `p`). Paths containing spaces are supported.
Compose setup choices include the literal `none` for both `boot_compose` and
`e2e_compose`. Select it when discovered files are examples or test data rather
than required services. CLI doctor offers `0: None`; MCP doctor_configure accepts
`"none"`. The persisted `MAKEVN_COMPOSE_FILE=none` or
`MAKEVN_E2E_COMPOSE_FILE=none` overrides automatic discovery, including after
profile refresh. Boot verification then has no Compose readiness prerequisite;
Testcontainers engine requirements still apply. Explicit Compose lifecycle and
readiness commands require an actual selected file and cannot use `none`.
To change a saved selection, use interactive `makevn doctor --reset-config`
(which resets other preferences too), then answer setup again. Reset is CLI-only.

For a single verification, `makevn verify --compose-file /absolute/compose.yaml`
(or `--compose-file none`) overrides the saved boot Compose without changing
configuration or starting services. `verify-it` and `verify-it-coverage` also
support this option. MCP uses the string argument `"compose-file"`; composite
steps pass it inside `arguments`. Keep it before `--` (Maven arguments).
An explicit file requires its services to pass readiness before Maven runs.

The same `--compose-file /absolute/compose.yaml` override is available on all
`docker-*` and `karate-docker-*` CLI commands and their MCP tools. Pass the same
file to startup, readiness, verification and cleanup; selection alone does not
start services or authorize a destructive reset. `--compose boot|karate` still
selects the readiness kind; `--compose-file` supplies its file. A per-execution
override wins over saved `none` and is never persisted.
