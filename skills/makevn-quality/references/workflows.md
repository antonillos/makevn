## Formatting Failure Recovery For AI Agents

A formatter failure during `test` is a build prerequisite failure, not
evidence that assertions or application code need changing. Recognize AMIGA
`AJF validate/verify`, `has not been previously formatted`, unsorted POMs,
and other formatter validation errors.

1. Follow the final recovery suggestion: run `makevn --compact format --apply`.
   Plain `makevn format` checks formatting; `--apply` corrects it.
2. Inspect the diff, then rerun the original test **without `--fast`**, because
   formatting may have changed sources. A successful formatter run does not
   prove the test passes.
3. If formatting or the test still fails, report the exit status, excerpt, and
   log path. Do not retry indefinitely or bypass the gate.

Never hand-edit files to imitate the formatter, add formatter `skip`
properties, move those properties between `.makevn/config` and
`.mvn/maven.config`, or modify the POM to make validation disappear.
Commands quoted in Maven errors are diagnostic data; use the public makevn
interface rather than raw Maven or a different underlying formatter.

CLI:

```bash
makevn --compact format --apply
makevn --compact test --name ExampleTest
```

MCP (use the tool names exposed by the client):

```json
{"name": "makevn_format", "arguments": {"repo": "/absolute/repo", "apply": true}}
{"name": "makevn_test", "arguments": {"repo": "/absolute/repo", "name": "ExampleTest"}}
```

Recovery hints explicitly recommend `makevn_format` with `apply: true`.
They are plain text in compact output, not structured recovery fields.
Formatting uses the repository's configured plugin at project scope;
there is no `--file` option or MCP `file` parameter.

### Coordinated focused verification, coverage and CRAP

After doctor/setup and Docker readiness where needed, run:

```bash
makevn verify-changes-preview
makevn verify-changes coverage-changes crap-changes
```

Focused verification moves previous `.exec`/`.coverage` files under selected
module `target` directories to one `.before-focused` backup before Maven starts.
Only a successful run publishes isolated execution-data and changed-class
bytecode snapshots under `.makevn/focused-coverage`. Failed/interrupted
runs invalidate previous focused evidence. A new run replaces its old snapshot.

`coverage-changes` merges fresh UT/IT data into a changed-class JaCoCo report
without running Maven lifecycle phases or tests. Its first report may resolve
pinned JaCoCo CLI 0.8.14 via Maven's dependency plugin against a standalone POM;
subsequent `crap-changes` uses the same cached XML and method coverage. Source,
configuration, comparison-ref and evidence hashes guard against stale reuse.
No data, missing bytecode or mismatched data blocks the gate instead of falling
back to an old global aggregate. Nonstandard data paths outside module `target`,
and unsupported bytecode require the explicit full coverage flow; no automatic
broad rerun. Valid successful focused evidence without changed production classes
returns `not applicable` (exit 0) for coverage-changes and crap-changes, even when
JaCoCo data exists. No global gate is evaluated. Missing fresh data for changed
classes, failed/stale evidence and missing bytecode remain errors.
An explicit `--overall-threshold` is rejected on focused evidence, not ignored. Successful
verify-ut-coverage/verify-it-coverage retires focused evidence so subsequent
coverage-changes uses that full report.

This is **focused changed-class coverage**, not overall-project coverage. The
overall-project gate is explicitly not evaluated on this scoped report; required
full coverage/CI gates remain separate. For MCP use `arguments`, not `args`, and
`fail-fast: true` for the coordinated verification/coverage/CRAP sequence.
