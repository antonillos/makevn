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
| Mutation | `makevn mutation` | `mutation` | Supported PIT report and requested result |

Use only detected supported plugins or explicitly configured goals; never invent
goals or bypass validation. If JaCoCo data is missing/empty, configure required
`MAKEVN_COVERAGE_PROP_FLAGS` in `.makevn/config`, run `makevn profile refresh`, then
rerun the appropriate coverage-producing flow. Do not switch to raw Maven.

### Changed-code checks

Inspect `verify_changes_preview` separately. Then reuse the same focused evidence:

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

Do not prepend clean or rerun tests without a reason. A valid run with no changed
production classes returns `not applicable` for changed-code metrics with exit zero:
no global gate was evaluated. Missing/stale evidence for changed classes still fails.
For global coverage use complete coverage-producing suites and the aggregate gate.
Local results never replace mandatory CI gates. In MakeVN's own development, the
Rust/Bash CRAP ratchet is authoritative in PR CI and must pass before merge.
