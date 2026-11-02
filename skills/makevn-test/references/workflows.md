## Running Specific Tests

**Use `makevn test --name`** when the goal is to run one or more specific test classes. This works for any test type — unit tests (UT) and integration tests (IT) alike.

```bash
# Run a single test class
makevn test --name SampleFeatureTogglesTest

# Run multiple test classes (two equivalent forms)
makevn test --name SampleFeatureTogglesTest,DeleteSampleItemsByVariantGroupCommandHandlerTest
makevn test --name SampleFeatureTogglesTest --name DeleteSampleItemsByVariantGroupCommandHandlerTest

# Skip compilation only after a successful compile or test run when sources have not changed
makevn test --fast --name SampleFeatureTogglesTest
```

Do not use `--fast`/`fast=true` on the first test attempt in a repository or
after changing source/test files. First run `makevn test --name ...` without
`--fast`, or run `makevn test-compile`/`makevn compile-tests`. Use fast mode only
for a repeated run after compilation has already succeeded.

For MCP, omit the `fast` parameter on the first `makevn_test` call. Passing
`fast=false` is equivalent to the normal compile-aware mode; `fast=true` is the
only mode that skips compilation.

Pass extra Maven flags after `--` on the matching typed command when needed.

## Choosing focused versus complete verification (mandatory agent rule)

Changed-code preview and verification are **focused by default**. Explain the
scope; the user need not name `--focused`. No flag or explicit `--focused` uses
focused execution. Only explicit CLI `--exhaustive` or MCP `focused: false` broadens
to complete selected owner/dependency suites. Keep the same mode in preview and
execution. Unknown/root impact stops and recommends exhaustive; never silently
broaden a run. Full verification/CI/coverage requirements still need their gates.
Doctor/setup and required Docker readiness come first.

```bash
makevn verify-changes-preview
makevn verify-changes
```

For MCP, use `focused: true` in both `verify_changes_preview` and `verify_changes`
with the same repository. Inspect the preview's per-owner suites/test list before
execution; do not preview focused and execute exhaustive mode.

**What the agent must understand and explain:**

- Preparation compiles/packages/installs necessary checkout dependencies with
  UT/IT execution disabled, while retaining test compilation/test jars. It updates
  local Maven artifacts. Its `-am install` reactor may still list 34 modules:
  that is not evidence that all their suites ran.
- Verification runs without `-am`: validated evidence-selected tests when available, otherwise full production/POM-consumer owner suites,
  selected changed test classes in other owners. A categories change plus a boot
  IT therefore does not require the complete boot suite in this mode.
- UT and IT selectors are separated; selected tests must have fresh non-skipped
  XML evidence from the expected plugin. Maven exit zero is not enough.
- Changed helpers/deleted tests expand to their complete owner suite. Unknown/root
  impact rejects focus; explain the reason before choosing a broader run.
- Focused success does not prove all impacted integration behavior or global
  coverage. Report “focused checks passed” with the tested scope, and retain
  mandatory full CI/coverage/CRAP gates.

To diagnose a large reactor, read the **phase and Maven command**, not just the
module list. Preparation must use `-am install` with skip flags; owner verification
must not use `-am`. If preparation really executes dependency suites, investigate
project configuration instead of blindly retrying.

CLI `--exhaustive` runs complete selected owner/dependency suites; whole-project
verification is `makevn verify`. No flag/MCP omission selects focused;
MCP `focused: false` is explicit exhaustive.
Never pass Maven test/skip/reactor overrides to focus or disable fresh-report checks.
The rules in this reference are the maintained decision contract.

Root version properties used only as direct dependency versions in immediate
local children can select consumer suites without dependencyManagement. Module
resources, including Avro test schemas, select their complete owner suite.
Unknown impact still stops focused planning and names the blocking paths.

For valid successful focused evidence with no changed production classes,
coverage-changes and crap-changes return `not applicable` with exit 0. JaCoCo
data may still exist; no global coverage/CRAP gate was evaluated. Do not repeat
tests or install analyzers for that outcome. Missing fresh data for changed
classes and stale/incomplete evidence still fail; global CI gates remain required.

Shared root fixtures do not require manually maintained configuration. Init/doctor
and previews/runs regenerate `.makevn/impact.json` from the current reactor;
selection never trusts generated state. Plain aggregator shared test resources
conservatively select all reactor module suites. Explain the visible scope and
that external/E2E/global gates are not evaluated; unknown models still reject.
Impact state is internal only; do not create or maintain root impact overrides.
Keep required external checks separate.

### Preview scope outcomes

When focused impact is unknown, `verify-changes-preview` completes with exit 0
and reports `requires exhaustive scope`, the blocking paths, and that no tests
ran or focused plan was produced. This is a planning outcome, not verification
success. Inspect another preview with `--exhaustive` (MCP `focused: false`) and
explain its scope before executing in the same mode. Preserve existing user
authorization; do not ask again solely because the preview needs broader scope.
Actual planner failures remain errors. `verify-changes` still rejects unsafe
focused execution and never silently broadens the run.

### Generic contract and shared-resource impact

Nested leaf dependency-version bumps select local transitive consumer suites.
No manually maintained impact JSON is required. Init/doctor and every preview/run
refresh disposable `.makevn/impact.json`; selection never trusts that snapshot.
Shared root test resources in a plain unconditional aggregator default to all
reactor module suites, visibly listed in the plan. This classified Maven-only
scope does not prove external/E2E or global gates. Ambiguous models still stop;
never infer owners from company/module/schema names or ignore fixtures.
Impact state is internal only: do not create or maintain root impact overrides.
Keep required external checks separate; automatic Maven scope does not prove them.
See Focused impact (see the selection rules above).

### Reusable test impact within one module

Use the selected classes and fallback reason in the preview. Evidence is captured
only with explicit `--record-test-impact` (MCP `"record-test-impact": true`), passed
to both preview and verification. This expensive baseline runs a complete suite
and then isolates every test class, including forks. Do not substitute ordinary
`test --name` results or aggregate JaCoCo for that map. Narrowing supports standard single-module Java layouts and JDK 17+. Compatible
method-body changes can reuse a map; new/deleted classes, changed declarations,
imports/initializers, helpers, configuration, resources, dependencies, generated
sources and JDK changes retain complete suites. A fresh map includes isolated JVM
class-load evidence and conservative transitive source consumers; recognized
dynamic consumers expand selection. Dynamic behavior in the changed class rejects
narrowing. Maps are disposable managed state; never write them by hand.

### Initialize or resume test-impact evidence

After doctor/setup, inspect `test_impact_preview`, then explicitly run
`test_impact_init`. These commands support a clean checkout; normal verification
never seeds a map automatically. The first capture runs a complete suite and
isolated test classes. Repeated initialization of an identical complete map runs
no tests. Identical partial checkpoints reuse completed classes after another
successful complete suite; changes invalidate reuse with diagnostics.
`verify_changes` with `record-test-impact: true` shares this checkpoint store.
Do not disable project coverage gates to make isolated captures pass. A partial
map is not eligible for narrowed verification and is not coverage/CRAP evidence.

### Partial suites and global coverage gates

A selected-suite `verify-changes` still executes Maven verify and can fail its
project-wide JaCoCo threshold after all selected tests pass. Default behavior
preserves that failure. For explicitly authorized local changed-code feedback:

```bash
makevn verify-changes-preview --defer-global-coverage
makevn verify-changes --defer-global-coverage
makevn coverage-changes
makevn crap-changes
```

MCP uses `defer-global-coverage: true` in both preview and verification, then the
usual fail-fast composite. This defers only property-based standard/Apache Commons
JaCoCo failure, keeping instrumentation, warnings, tests and other gates. Custom
literal configurations can still reject the run. Do not use the flag for
exhaustive verification or impact capture. Full verify/CI coverage is a separate
required result. Report the scope and deferral explicitly.
