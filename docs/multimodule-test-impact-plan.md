# Progressive test impact in Maven reactors

Static initialization and normal runtime enrichment support literal local Maven
reactors with standard Java source layouts on JDK 17+. Explicit isolated capture
remains single-module only.

## Selection and state

The map uses `progressive-reactor-v1`, with module-relative source paths and
`module::fully.qualified.Class` identities. Source-free aggregators contribute
Maven relationships but no test candidates. All Java sources are parsed in one
JVM invocation per snapshot; focused owners share the current and comparison
snapshots rather than reparsing the reactor for each owner.

`reactor_impact.reactor_consumers` expands changed Java owners to their transitive
consumers before narrowing tests. Its closure includes local inherited and profile
dependencies, plugins and parent relationships. Source reference aliases retain
all matching classes conservatively, including duplicate simple names and
interface/base-type connections. Ambiguity can therefore select extra tests;
absence of a static match retains the complete consumer suite.

Focused preparation installs every planned owner and required upstream outputs
once without tests. Verification then runs each owner without `-am`. The plan is
rechecked after preparation, including mixed selected/full owner suites, so newly
generated sources cannot silently invalidate a selected scope. Normal verification
still retains the Maven verify lifecycle and its existing quality gates.

## Runtime observations

Fresh successful Surefire/Failsafe reports establish module-specific test
identities. Loaded-class traces contribute execution-wide production dependency
supersets, never precise attribution for individual tests. A raw loaded class
name matching several reactor classes conservatively contributes all matching
identities. A report from another module cannot establish that a selected test
ran or make its skipped result optional.

Observations only add selection edges. They are merged atomically under the
existing lock. Reactor membership, coordinates/configuration, source declarations,
Java context, ignored runtime resources and dependency artifact changes invalidate
incompatible evidence. Ordinary method-body edits preserve compatible observations.
Init/preview run no Maven or tests, and learning never replays an execution.

## Conservative limits

Profile-defined or unresolved module membership, ambiguous Maven coordinates,
custom Java source/output roots, additional-source goals, generated Java and
custom settings/repository inputs cannot establish a usable static reactor map.
Unknown test filters, declarations, resources and shared/global state changes
retain complete suites. Unknown owner/consumer scope requires exhaustive preview
rather than silently omitting verification. Maven-root consumers still require
exhaustive verification.

When additional-source declarations block static initialization,
`test-impact-preview` reports declared roots and, where safely resolvable, their
owners and complete downstream suites. Its `requires_exhaustive_scope` result is
only a preview: run `verify-changes --exhaustive` explicitly to execute tests.
Unresolved expressions, inheritance, or other ambiguous declarations are reported
as `unsupported` with unknown roots and the same exhaustive next action. Neither
outcome creates a static map or runs Maven tests.

## Verification

The reactor regression suite covers `core -> service -> app`, an independent
module, duplicate test names, test fixtures, runtime enrichment, optional/failed
reports, configuration drift, custom filters and profile membership. Existing
single-module, isolated-capture and reactor-scoping regressions remain applicable.

An isolated Petclinic Microservices clone (8 modules, 62 sources, 8 test classes)
initialized its static map in approximately 0.76 s on JDK 25. Focused verification
then executed one selected test and enriched its module-qualified observation.
A clean Karate clone correctly retained full consumer suites because it declares
additional Java source roots. See the [validation report](test-impact-reactor-validation.md)
for revisions, evidence and timing limits. CI smoke and the CRAP ratchet remain
required before merge.
