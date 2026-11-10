---
name: makevn-quality
description: >-
  Use for MakeVN formatting, Checkstyle, coverage, changed-code CRAP, mutation testing and distinguishing local evidence from whole-project or CI quality gates.
---

# MakeVN quality

Load [makevn](../makevn/SKILL.md) first if not already read; finish doctor/setup.
Read [quality recipes and recovery](references/workflows.md) before changing formatting.
Load [makevn-test](../makevn-test/SKILL.md) for verification and
[makevn-docker](../makevn-docker/SKILL.md) only when tests require containers.

| Goal | CLI | MCP | Evidence |
| --- | --- | --- | --- |
| Formatting check / correction | `makevn format` / `makevn format --apply` | `format` / `format` with `apply: true` | Plugin succeeds; inspect resulting diff and retry original test without fast |
| Checkstyle | `makevn checkstyle` | `checkstyle` | Supported configured check succeeds |
| Produce full-suite coverage | `makevn verify-ut-coverage` or `makevn verify-it-coverage` | `verify_ut_coverage` / `verify_it_coverage` | Fresh JaCoCo classes and execution data |
| Aggregate coverage | `makevn coverage` | `coverage` | Existing report meets requested threshold |
| Changed-code coverage / CRAP | `makevn coverage-changes` / `makevn crap-changes` | `coverage_changes` / `crap_changes` | Fresh matching changed-class evidence and gate outcome |
| Install CRAP analyzer | `makevn crap install-analyzer` | `crap_install_analyzer` | Pinned download passes SHA-256 verification |
| Mutation | `makevn mutation` | `mutation` | Supported PIT report and requested result |

For Checkstyle, inspect doctor's `Checkstyle support: yes` signal (CLI JSON:
`repository_analysis.checkstyle_available` is `yes`). This reports availability;
run `checkstyle` and inspect its exit status to establish success. See the
[Checkstyle recipe](references/workflows.md#checkstyle) for detection and configuration.

Use only detected supported plugins or explicitly configured goals; never invent
goals or bypass validation. If JaCoCo data is missing/empty, configure required
`MAKEVN_COVERAGE_PROP_FLAGS` in `.makevn/config`, run `makevn profile refresh`, then
rerun the appropriate coverage-producing flow. Do not switch to raw Maven.

### Changed-code checks

Before queuing coverage/CRAP steps, inspect the fixture's effective JaCoCo
agent configuration, including inherited parents and active profiles. Use
MCP `jacoco_inspect` (CLI `makevn jacoco-inspect`) for explicit Maven effective
model inspection after doctor/setup. Its `configured`/`absent`/`unknown` statuses
concern plugin bindings, not agent execution or custom instrumentation. It runs
no tests and may resolve Maven plugins; the preview itself remains Maven-free. When JaCoCo
is confirmed absent, run verification only: omit `coverage_changes` and
`crap_changes` from the composite and report coverage/CRAP as unavailable because
the project does not configure JaCoCo. Do not make calls merely to obtain an
expected error or skip. No local declaration alone does not prove absence when
parent/profile configuration is unresolved; resolve that uncertainty first.
When an agent is configured, preserve the normal verification/coverage/CRAP flow;
missing or stale execution data remains an error, never an automatic skip.

Inspect `verify_changes_preview` separately. For projects with configured JaCoCo, reuse the same focused evidence:

```json
{
  "tool": "composite_run",
  "arguments": {
    "steps": [
      {"tool": "verify_changes", "arguments": {"focused": true}},
      {"tool": "coverage_changes"},
      {"tool": "crap_changes"}
    ],
    "fail-fast": true
  }
}
```

Validated test-impact selection retains the same fresh focused snapshot contract;
coverage and CRAP share that new run's data, never the baseline capture data.
Do not prepend clean or rerun tests without a reason. A valid run with no changed
production classes returns `not applicable` for changed-code metrics with exit zero:
no global gate was evaluated. Missing/stale evidence for changed classes still fails.
For global coverage use complete coverage-producing suites and the aggregate gate.
Local results never replace mandatory CI gates. In MakeVN's own development, the
Rust/Bash CRAP ratchet is authoritative in PR CI and must pass before merge.

If CRAP reports the analyzer is missing, use `crap_install_analyzer` explicitly,
then retry the affected CRAP operation using the existing fresh evidence. The
installer downloads a pinned release and verifies its checksum; CRAP checks do
not download it automatically.

`test-impact-init` prepares selection evidence, not a coverage snapshot for a
later edit. After capture, preview and run verification for the actual change
before coverage/CRAP. Project-wide JaCoCo gates can reject isolated capture;
report the gate and stop rather than disabling it.

### Explicit local deferral of global JaCoCo failure

When the user authorizes changed-code feedback separately from full coverage,
preview and execute verify_changes with `defer-global-coverage: true` (CLI
`--defer-global-coverage`). The flag is opt-in, focused-only and forbidden for
impact capture. It sets only `jacoco.haltOnFailure=false` and
`commons.jacoco.haltOnFailure=false`; agents and warnings stay enabled. It does
not defer arbitrary coverage/check plugins or literal configuration. Tests and
other Maven failures still stop the fail-fast workflow. Run coverage_changes and
crap_changes from the fresh successful snapshot and report the actual incremental
gates. Retain the separate complete-suite/global coverage requirement; a local
success is not global approval. Never change POM rules or enable this implicitly.
