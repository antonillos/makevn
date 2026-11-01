# Project-wide test-impact initialization

Status: proposal; the commands below are not implemented.

## Problem

The current `verify-changes --record-test-impact` requires changed verification
inputs and starts a complete capture. A clean checkout cannot seed a map, and an
interrupted isolated capture must repeat already completed work. Introduce an
explicit project-wide initialization workflow and let changed-code recording
complete compatible evidence from that workflow.

Here, project-wide means the current Maven checkout, not a shared machine-wide
cache. Initial support remains a standard single-module Java project on JDK 17+.
Multimodule and generated-source support require separate work.

## Proposed public contract

Add `makevn test-impact-preview` and `makevn test-impact-init`, with corresponding
MCP tools `test_impact_preview` and `test_impact_init`. They work on a clean
checkout after the normal doctor/setup workflow. Initialization is explicit
because the complete suite and isolated per-class executions can be expensive.

The preview reports supported layout, evidence compatibility, known completed
classes and remaining capture work. Before running a fresh complete suite it
must describe the inventory as provisional rather than claiming an exact cost.
It runs no tests. A valid compatible map produces a no-op initialization.

Initialization runs preparation and a successful complete suite to establish a
fresh inventory before capturing missing classes. Both commands report why any
previous evidence cannot be reused. They must not disable repository coverage
rules or test failures to produce a successful map.

`verify-changes --record-test-impact` checks the same evidence store. It reuses
compatible completed records and captures missing classes. It still requires
the complete-suite prerequisite before publishing a newly completed map. Normal
`verify-changes` never starts capture automatically.

## Compatibility and recovery

Reuse completed records only when the entire capture context is identical:
source/test/resource/configuration inventories, baseline revision and checkout,
JDK, environment, compiled bytecode, Maven models and resolved dependencies.
Validate dependency and project archive evidence before reuse, including records
from an interrupted capture. Artifact integrity must be checked rather than
trusting a record merely because its test name exists.

The first implementation should resume an interrupted capture of an unchanged
context. It must not retain unrelated-looking test records after production or
test inputs change: proving partial invalidation safe is separate work. Any
incompatible context starts a fresh capture with a visible explanation.

Persist completed per-class records atomically after validating fresh test
reports and class-load traces. Seal the checkpoint so partial/corrupt files
cannot be mistaken for reusable records. A failed class is missing work, never a
completed record. Changing context during capture prevents publication.

An in-progress checkpoint is not eligible for narrowed verification. Publish a
map atomically only after every discovered class has a successful isolated record
and the final context validation succeeds. Coordinate executions per checkout
so concurrent initializers cannot overwrite each other's state.

## Evidence and reporting

Report whether initialization reused a complete map, resumed a checkpoint or
started fresh, together with completed/reused/executed class counts, failures,
exit status and log paths. Retain checkpoints after failures for diagnosis and
safe resumption. Distinguish capture cost from subsequent focused test cost.

Coverage and CRAP continue to use fresh verification snapshots; a capture map
is never coverage evidence. Explain when repository-wide Maven verification
gates make isolated replay unavailable, as observed in Commons Lang.

Update CLI/MCP help and the test, quality and product-test skills together. The
test skill must explain the clean-checkout workflow, explicit capture cost,
resume eligibility and full-suite fallback.

## Acceptance criteria

- A clean supported checkout can initialize a map without fabricating a diff.
- Repeating initialization with identical complete evidence runs no tests.
- Interrupting a capture and restarting with identical inputs reuses completed
  classes, executes missing classes and publishes only a complete validated map.
- Changed-code recording can complete the same compatible checkpoint.
- Source, tests, resources, configuration, dependencies, JDK or other validated
  context changes invalidate reuse and print a specific reason.
- Failed, skipped-only, corrupted or concurrently modified evidence cannot
  enable narrowed selection.
- After initialization, a compatible production edit selects its direct tests
  and conservative consumers; an unrelated test can be excluded in a fixture.
- Regressions cover CLI/MCP parity, preview behavior, safe interruption,
  invalidation, locking and fresh coverage/CRAP evidence. Validate the workflow
  against a passing real Maven repository as well as synthetic fixtures.
- Run the repository's smoke and mandatory CI CRAP gates before merging the
  implementation. This proposal does not establish runtime validation.
