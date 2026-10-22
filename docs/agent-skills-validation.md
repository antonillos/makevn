# Agent skill validation

Use isolated homes and repositories. Never overwrite a real client's configuration
or change trust/permissions merely to make a test pass. Record the MakeVN version,
client version, scope and exact outcome. Do not label disk checks as model tests.

## Four independent checks

1. Distribution: all five skills and references are installed; local links resolve.
2. Discovery: `agent status` reports current registration, then the client catalog
   lists all five names/descriptions without duplicates or errors.
3. Explicit loading: ask the client to load each named skill, without running its
   workflow. Confirm the client's skill invocation or file-read event and contents.
4. Implicit selection: use the requests below in fresh sessions without naming a
   skill. Record selected skills, prerequisite decisions and stated evidence.

Use the client's official commands/API for its installed version. OpenCode API
and Codex `skills/list` can inspect discovery without a model run. With OpenCode
2.0.32, initialize plugins/agents in the same persistent server (for example
`plugin.list`, then `agent.list`) before inspecting `skill.list`; a one-shot
catalog request can run before plugin initialization finishes. A successful
catalog response does not prove explicit loading or implicit selection. Model runs
need a configured provider and credentials; report them as unverified if unavailable.

## Representative requests

| Request / fixture | Expected skills and behavior |
| --- | --- |
| “Set this repository up for Java builds”; no Maven signals | makevn; doctor reports unsupported, no init/refresh/verification |
| “Build this Maven project”; supported, uninitialized | makevn; doctor → recommended init → doctor; requested phase only |
| “Run ExampleTest”; supported, initialized | makevn + makevn-test; compile-aware test, selected report evidence |
| “Verify my changes quickly” | makevn + makevn-test; focused preview inspected before same-mode execution, explain preparation and owner suites |
| Unknown focused impact | Explain blocking paths and inspect exhaustive preview within authorized scope; no silent expansion |
| Ambiguous boot/E2E Compose | makevn + makevn-docker; ask offered choices and submit doctor_configure token, no guessed config or startup |
| “Run ITs”; configured container prerequisite | makevn + makevn-test + makevn-docker; check readiness, reuse healthy stack, no unauthorized reset |
| “Run Karate end to end”; no health URL | makevn + makevn-karate; resolve health setup before managed Docker/package/test flow |
| “Run Karate against the running external app” | makevn + makevn-karate; confirm target and use karate-test without taking over external lifecycle |
| “Check coverage and CRAP of my changes”; no changed production classes | makevn + makevn-test + makevn-quality; reuse valid snapshot, report not applicable and global gates unevaluated |
| Formatting prerequisite failure | makevn-quality; format --apply, inspect diff, retry original test without fast |
| Interrupted verification | makevn; inspect execution status/ownership, cancel only owned work, confirm terminal state before retry |

Implicit selection is model-dependent. Judge correct decisions and evidence, not
whether a model uses a particular natural-language phrase. Document failed cases
and improve descriptions or recipes without claiming deterministic activation.

## Implementation validation record (2026-10-22)

- Codex CLI 0.152.0: isolated HOME/CODEX_HOME, `initialize` followed by
  `skills/list` with `forceReload: true`; all five global skills discovered,
  enabled, no skill errors.
- OpenCode 2.0.32: isolated HOME/XDG directories and persistent local server;
  plugin/agent initialization followed by `skill.list`; all five global skills
  discovered from `.agents/skills` with their bodies and supporting paths.
- Registration in both clients and scopes, nested-worktree root selection,
  read-only status, idempotence, conflicts, updates and recovery are covered by
  automated tests. These are not model behavior assertions.
- Explicit model-driven loading and implicit workflow selection remain unverified:
  no provider/model credentials were configured in the isolated client homes.
  Use the scenario matrix above in an authenticated client before claiming those
  behavioral acceptance criteria. No real client configuration was modified.
