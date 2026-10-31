---
name: makevn-docker
description: >-
  Use for MakeVN container prerequisites, Compose selection, readiness, diagnostics, logs and authorized boot or Karate container lifecycle. All Docker operations must use MakeVN.
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
are preserved. Engine/context failures block tests and require environment
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
