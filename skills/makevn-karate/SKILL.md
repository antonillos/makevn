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
authorization for the full lifecycle invoked by `karate-all`.

| Intent | CLI | MCP | Evidence |
| --- | --- | --- | --- |
| Managed application + E2E | `makevn karate-all --tag @smoke` | `karate_all` with `tag` | Required services ready, HTTP health ready, Karate results, application cleanup |
| Existing external application | `makevn karate-test --tag @smoke` | `karate_test` with `tag` | Target application confirmed and requested Karate tests ran |
| Manual managed application | `makevn run-app-bg`, then `makevn karate-test`, finally `makevn stop-app` | `run_app_bg`, `karate_test`, `stop_app` | Stop after any prerequisite failure; perform application cleanup even on test failure |

`karate-all` owns application cleanup; do not assume it tears down containers.
Container teardown is a separate authorized operation. Do not stop an externally
managed application. Standalone process liveness is not HTTP readiness, and HTTP
readiness does not prove application semantics, JSON health status or Kafka readiness.
