---
name: makevn-test
description: >-
  Use for selected Java tests, UT/IT suites, focused changed-code checks, exhaustive or full verification, test evidence and build/test failure diagnosis through MakeVN.
---

# MakeVN tests

Load [makevn](../makevn/SKILL.md) first if not already read; finish doctor/setup.
Read [workflow details](references/workflows.md) before selecting scope.
Load [makevn-docker](../makevn-docker/SKILL.md) when doctor/config/profile/test
signals establish a Docker prerequisite. A root compose file alone does not.
Testcontainers dependencies also establish an engine prerequisite: load
makevn-docker for that workflow even without Compose. Tests may use Surefire;
do not infer Failsafe ownership from `@Testcontainers` or Spring annotations.
MakeVN checks the engine and forwards a local Docker context before test execution;
without Compose the tests own container startup, so no `docker_up` is needed.

| Goal | CLI | MCP | Evidence |
| --- | --- | --- | --- |
| Selected UT or IT classes | `makevn test --name ExampleTest,ExampleIT` | `test` with `name` | Selected classes actually ran; fresh reports |
| Complete UT suite | `makevn verify-ut` | `verify_ut` | UT results for requested scope |
| Complete IT suite | `makevn verify-it` | `verify_it` | IT results after required readiness |
| Whole project | `makevn verify` | `verify` | Full requested verification results |
| Changed code | preview then `makevn verify-changes` | `verify_changes_preview`, `verify_changes` | Reviewed scope and fresh Surefire/Failsafe evidence |

MCP `test` accepts explicit Maven user properties through `properties`, for example
`{"name":"ExampleTest","properties":{"skipEnforceSnapshots":"false"}}`.
Values must be strings. Use repository intent or user answers to choose values;
do not infer skip flags from another workflow. This forwards the same properties
as CLI `test --name ExampleTest -- -DskipEnforceSnapshots=false` and lets the
Maven preflight inspect them. An unresolved property still blocks execution.

Preview and execution must use the same repository and mode. Focused is the
default; `--exhaustive` / `focused: false` selects complete owner/dependency suites.
Exhaustive selected suites still differ from whole-project `verify`. Unknown impact
requires another exhaustive preview and explanation; never silently broaden.
A successful preview runs no tests. Preserve existing authorization when broadening.

Preparation uses `-am install` with UT/IT execution disabled and retains test
compilation/test jars. A 34-module reactor does not mean 34 suites ran. Owner
verification runs without `-am`, with separate UT/IT selectors and fresh non-skipped
XML evidence. Maven exit zero alone is insufficient. Report “focused checks passed”
with actual scope; full CI, coverage and CRAP gates remain separate.

Omit `fast` on first runs or after source/test edits. For stale generated-source
compilation failures, call MCP `clean` with `clean-generated-contract-targets: true`
and the same `repo`; for direct CLI use, run
`makevn clean --clean-generated-contract-targets`. After cleanup succeeds, retry
the original test or verification with the same scope and Maven properties, without
fast mode. The cleanup flag belongs only to `clean`, never `test` or verification
tools. If cleanup fails, inspect its `untrustedData` and `logPaths` and correct the
cause before retrying; do not switch to CLI help or another command to bypass an
MCP failure. Do not prepend clean without evidence. Cleanup success does not prove
that any tests ran.
Formatter prerequisite failures use [quality recovery](../makevn-quality/SKILL.md).
Missing tools are environment issues; failures after reaching Maven are repository
failures; documented-command parser failures can be MakeVN product bugs. Report
exit code, a short failure excerpt and log paths before deciding what to change.

For changed-code coverage/CRAP, load [makevn-quality](../makevn-quality/SKILL.md)
and reuse the same successful evidence instead of repeating tests.
