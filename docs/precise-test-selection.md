# Progressive test selection in Maven projects

Focused verification starts with conservative static Java dependencies. Standard
single-module and literal local reactor Java layouts on JDK 17+ are supported. Generated Java,
unknown build/resource impact and unresolved dependencies retain complete suites.
See the [reactor implementation notes](multimodule-test-impact-plan.md) for
module identity, consumer selection and supported-layout limits.

## Start without running tests

`makevn init` (including `--force` / `refresh`) automatically saves the static map
when a compatible JDK is selected and the layout is supported. Repeating init
refreshes it while retaining compatible runtime observations. Dry runs never
write a map. Missing Python/JDK or unsupported layouts defer analysis visibly
without failing repository initialization; resolve setup and retry with
`makevn test-impact-init`.

After doctor/setup:

```bash
makevn test-impact-preview
makevn test-impact-init
makevn verify-changes-preview
makevn verify-changes
```

Preview is read-only. Initialization writes `.makevn/test-impact/progressive.json`
without Maven, compilation, packaging, tests or container startup. A JDK is used
only to parse Java syntax. Focused planning also works without initialization and
never writes a map. It compares changed sources with the Git comparison baseline,
including removed references, rather than assuming the edited graph is complete.
When class-map initialization is unavailable, `test-impact-preview` reports the
reason and whether module-level selection can still be planned. Run
`verify-changes-preview` to see the affected complete module suites before any
verification. An unresolved module or dependency graph is reported explicitly;
the impact preview never runs tests.

The static inventory includes Surefire's `Test*`, `*Test`, `*Tests`, and `*TestCase`
conventions, including annotation-free JUnit 3 classes. Configured Surefire/Failsafe
class includes/excludes or filter files retain the complete owner suite.
Filter validation follows the selected owner's Maven parent chain, not sibling
modules or unrelated aggregators. Published parents are inspected only from the
local Maven cache; missing or unresolved parent models retain the complete suite
without downloading POMs or running Maven. Each planning pass reports identical
fallback reasons once, listing all affected owners together.

Static selection follows source references transitively, retains simple-name
collisions and nested/secondary type aliases, and conservatively connects related
production types in both directions to account for interface/base-type dispatch.
Framework contexts, reflection and conditional tests expand selection. Declaration,
import, initializer, helper, resource and configuration changes or possible shared
state writes in changed methods retain complete suites. No known dependency is
removed just because a previous execution did not exercise it.

## Learn during normal executions

Normal `test`, UT/IT, `verify` and focused verification commands collect JVM
class-load traces during the execution already requested. They never add test
replays. Successful fresh reports and matching test-class traces add production
class dependencies to the map. Failed commands/reports, stale reports, skipped
cases, missing traces and inputs changing during execution cannot supply edges.
A failed observation does not turn a successful Maven command into a failure.

A shared JVM does not identify which test caused each class load. Each executed
class therefore receives the conservative execution-wide superset. This can make
selection broader, especially after a complete suite; it never proves that an
unobserved dependency does not exist. Single-class runs provide a tighter superset.
Aggregate JaCoCo coverage is never treated as per-test evidence.

Repeated runs merge edges atomically under a checkout lock. Compatible method-body
edits preserve additive observations. Changes to declarations, source inventory,
configuration, resources, JDK/environment, revision or observed dependency JARs
invalidate observations; static selection remains available. Skipped classes and
conditional tests are always retained with fresh reports required. Activation must
pass. Static maps and observations are disposable managed state, not fresh test,
coverage or CRAP evidence. Do not edit them by hand.

## Optional isolated capture

```bash
makevn test-impact-init --isolated
```

MCP `test_impact_init` defaults to static initialization; `isolated: true` explicitly
requests the expensive capture. Changed-code capture remains available through
`--record-test-impact` in both preview and execution. It runs a complete suite and
then replays missing active classes, resuming only identical sealed checkpoints.
Its valid observations also enrich the progressive map.

The full suite executes `verify`, preserving packaging and verification gates.
Its coverage snapshot is retained before replays; failed capture revokes that
snapshot rather than publishing partial success.
Subsequent isolated unit classes execute `test`, retaining test compilation and
lifecycle instrumentation while avoiding repeated package/Shade work. Integration
classes retain `verify` because they may need packaged artifacts. No `clean`,
plugin skip flag or POM modification is introduced. Capture rechecks source,
bytecode, dependencies and context before publishing isolated evidence. Completely
skipped classes are not replayed and do not provide loading evidence.

## Coverage and CRAP

The narrowed run prepares dependencies without UT/IT, verifies selected
classes without `-am`, separates Surefire and Failsafe selectors and requires
fresh reports. Known optional tests may remain skipped. It publishes the normal fresh UT/IT and changed-class
bytecode snapshot. Coverage and CRAP reuse that snapshot, never baseline data.
Full verification and global coverage/CRAP requirements remain separate gates.

The Commons Lang BitField scenario cannot seed a valid baseline while its full
suite has timezone failures. In that state the correct result is an explained
full-suite fallback. A passing synthetic Maven regression covers direct tests,
transitive consumers, forks, parameterized cases and an unrelated test excluded
from a subsequent compatible production change. No reduction is claimed for
Commons Lang without a successful full baseline.

## Partial verification with a global JaCoCo rule

By default, focused verification preserves Maven verify gates. A partial suite
may pass all selected tests and then fail a global coverage threshold, as observed
on Commons CSV. For an explicit local changed-code workflow, use:

```bash
makevn verify-changes-preview --defer-global-coverage
makevn verify-changes --defer-global-coverage
makevn coverage-changes
makevn crap-changes
```

MCP uses `defer-global-coverage: true` in both preview and execution. The opt-in
flag sets `jacoco.haltOnFailure=false` and `commons.jacoco.haltOnFailure=false`
for preparation/verification. JaCoCo agents still record fresh data and its check
still prints rule violations. Test failures and other Maven verification gates
still fail. No POM or threshold is changed. Arbitrary coverage plugins and literal
haltOnFailure configurations are not overridden and can still reject the run.

The preview states that global coverage failure is deferred and that full
verify/CI remains required. The subsequent coverage/CRAP commands evaluate the
changed-code snapshot, not a global gate. This flag defaults to false and is
rejected with exhaustive mode or record-test-impact. Static initialization executes
no verification; isolated capture retains its complete-suite prerequisite.
