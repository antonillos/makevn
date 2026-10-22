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

| Goal | CLI | MCP |
| --- | --- | --- |
| Boot readiness | `makevn docker-ps-required --compose boot --wait-seconds 30` | `docker_ps_required` with `compose: "boot"`, `wait-seconds: 30` |
| Container listing / resource usage | `makevn docker-ps` / `makevn docker-stats` | `docker_ps` / `docker_stats` |
| Authorized boot start/reset / stop | `makevn docker-up` / `makevn docker-down` | `docker_up` / `docker_down` |
| Authorized Karate start / stop | `makevn karate-docker-up` / `makevn karate-docker-down` | `karate_docker_up` / `karate_docker_down` |
| Karate standalone readiness | `makevn docker-ps-required --compose karate` | `docker_ps_required` with `compose: "karate"` |

Readiness success is the prerequisite signal; listing containers is diagnostic.
Inspect logs already returned by MakeVN. Do not invent a logs/inspect command:
consult installed command help/tool schemas and report unsupported capabilities.
