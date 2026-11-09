---
name: makevn-docker
description: >-
  Expertise in container prerequisites, Compose selection, readiness, diagnostics and authorized container lifecycle. Load the makevn skill first, then this skill before using Docker tools such as docker_ps_required. All Docker operations must use MakeVN.
---

# MakeVN Docker

Load [makevn](../makevn/SKILL.md) first if not already read; finish doctor/setup.
Read [Docker prerequisite details](references/workflows.md) before lifecycle actions.

Use MakeVN exclusively for all Docker work, including discovery, diagnostics,
logs, inspection, networks, volumes and lifecycle. Prefer MCP, then supported CLI.
Never fall back to Docker/Compose commands, RTK wrappers, scripts, SDKs or APIs.
If MakeVN lacks the operation, report the missing capability and stop that action.
Unknown Compose/worktree ownership is not permission to reset or delete data.

For Testcontainers repositories, distinguish the Docker engine from Compose
services. With no Compose stack, do not call `docker_up` or invent a Compose file:
the tests create their own containers. MakeVN checks engine access before test
execution and forwards a local Unix Docker context as `DOCKER_HOST` to Java when
that variable is unset. Explicit Docker and Testcontainers environment settings
are preserved. For `$HOME/.colima/<profile>/docker.sock` endpoints, MakeVN defaults
the child-only Ryuk socket override to `/var/run/docker.sock` when unset, while
preserving the macOS connection endpoint and any explicit override. Host-address
overrides remain user configuration. Engine/context failures block tests and require environment
diagnosis; `docker_up` does not start the Docker engine. See the reference for
remote/TLS and runtime-specific limits.

| Goal | CLI | MCP |
| --- | --- | --- |
| Boot readiness | `makevn docker-ps-required --compose boot --wait-seconds 30` | `docker_ps_required` with `compose: "boot"`, `wait-seconds: 30` |
| Container listing / resource usage | `makevn docker-ps` / `makevn docker-stats` | `docker_ps` / `docker_stats` |
| Authorized boot start / stop, preserving volumes | `makevn docker-up` / `makevn docker-down` | `docker_up` / `docker_down` |
| Explicitly authorized boot data reset | `makevn docker-reset` | `docker_reset` |
| Authorized Karate start / stop | `makevn karate-docker-up` / `makevn karate-docker-down` | `karate_docker_up` / `karate_docker_down` |
| Explicitly authorized Karate data reset | `makevn karate-docker-reset` | `karate_docker_reset` |
| Karate standalone readiness | `makevn docker-ps-required --compose karate` | `docker_ps_required` with `compose: "karate"` |

Readiness success is the prerequisite signal; listing containers is diagnostic.
If readiness fails only because services are missing or stopped, with resolved
setup/Compose selection and no probe errors or ownership conflicts, start the
matching stack under existing startup authorization and check readiness again.
Do not ask for reset authorization to start services. Up/down preserve volumes;
only reset removes the selected Compose project's volumes. No lifecycle command
prunes global volumes. Diagnose unhealthy services or mount failures before
considering an explicitly authorized reset. Missing services alone do not require
doctor, init or resetting doctor configuration.
Inspect logs already returned by MakeVN. Do not invent a logs/inspect command:
consult installed command help/tool schemas and report unsupported capabilities.
If `docker_up` fails after starting some services, inspect its log and the
affected service diagnostics before retrying. If the selected Compose project's
containers are left in a failed or partial state and stopping that project is
authorized, recover with the matching volume-preserving `docker_down`, then
`docker_up`, and check `docker_ps_required`. Do not infer the root cause from an
orphan warning or a service exit, or tear down an unrelated or unknown project.

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
