# Precise test selection within a Maven module

Focused verification can reuse an isolated test-to-class map for standard
single-module Java projects on JDK 17+. Missing or incompatible evidence retains
the complete owner suite and prints the reason. Reactors and generated Java
sources currently retain complete owner suites; cross-module narrowing is not
implemented.

## Initialize once, reuse for compatible method-body edits

After doctor/setup, initialize selection evidence on a clean or modified checkout:

```bash
makevn test-impact-preview
makevn test-impact-init
# After a compatible production method-body edit:
makevn verify-changes-preview
makevn verify-changes
makevn coverage-changes
makevn crap-changes
```

MCP exposes `test_impact_preview` and `test_impact_init`. The preview runs no tests
and reports compatibility and provisional cost. Initialization is explicit and
expensive: preparation, a complete suite, then isolated verification per test
class. Repeating it with an identical complete map runs no Maven or tests.

Completed per-class records are sealed and saved atomically. On interruption,
rerun initialization: it runs the complete suite again and replays only missing
classes if the capture context is identical. Source/test/configuration/resource,
revision, dependency, JDK, environment, compiled bytecode or Maven model changes
invalidate reuse. The first implementation does not attempt partial invalidation
across source edits. A per-checkout advisory lock prevents concurrent captures.
Partial checkpoints cannot enable narrowed verification. Publish the complete map
only after every class succeeds and final context checks pass.

Changed-code recording remains available with `--record-test-impact` (MCP
`record-test-impact: true`) in both preview and verification. It shares the same
checkpoint and reuses compatible records after the successful complete suite.
It requires changed inputs selecting the complete root owner suite; initialization
supports a clean checkout. Ordinary focused runs never capture automatically.

Capture requires fresh non-skipped Surefire/Failsafe reports and matching JVM
traces. Failed, entirely skipped or missing classes cannot be published. Nested
and parameterized cases belong to their top-level class. Custom test ownership,
reactors and generated Java remain unsupported. Repository-wide coverage rules
are not disabled and can prevent isolated replay from completing.

## Evidence and consumer expansion

The map records the superset of production classes **loaded** in each isolated
test execution and its child JVMs. JDK unified class-load logging provides this
without replacing the project's JaCoCo agent or adding a test framework listener.
A trace must contain the selected test class. Loading is more conservative than
method execution: merely loading a class can retain a test. Aggregate JaCoCo
cannot identify test classes and is never accepted as a substitute for this map.

Java's compiler parser derives source declaration fingerprints and conservative
identifier references without executing repository code. Consumer expansion uses
all matching simple type names, retaining collisions rather than resolving them
optimistically. Transitive consumers and explicitly changed tests are included. A reverse
reference index and queue visit each impacted simple type name once, retaining
name collisions and cycles without repeatedly scanning the source inventory.
Sources using recognized reflection/service-loading APIs are potential consumers;
their callers/tests are retained even without a direct static edge. Dynamic
behavior or recognized process-wide state/I/O effects in a changed production
class, including effects removed since the baseline, reject narrowing; local
class-loading evidence cannot bound those effects.
Changed method bodies containing assignments, compound assignments or increment/
decrement operations also retain the complete suite. Without attribution their
targets cannot be proven local. Both added and removed writes are checked;
unchanged constructors and other unchanged methods do not disable selection.

The baseline stores the Git revision, source/config/resource inventory, compiled
class hashes, resolved dependency JAR hashes, cached Maven model inventory and JDK
identity. Environment fingerprints are hashed without persisting secret values.
Rebuilt project JARs are validated against prepared class bytecode and stable
archive resources; changing ZIP timestamps alone does not invalidate the map.
Only compatible method-body changes and explicitly selected changed test classes
can reuse a map. Java declaration/import/initializer changes, new/deleted classes,
test helpers, generated sources, resources, POMs, dependency/configuration/JDK
changes, missing bytecode or an empty match use the complete suite. Custom Maven
settings/repository overrides are currently unsupported for narrowing.

Evidence lives under `.makevn/test-impact`. Atomic publication and integrity
checks reject incomplete or altered artifacts. This is disposable local build
state, not a security boundary against a user able to rewrite the state and its
checksums. Do not hand-maintain it. A capture requiring work retires the old map before tests; identical complete
initialization is a no-op.
Preparation revalidates bytecode before selected tests execute; incompatible
prepared output stops and requires a new preview, never silently widens execution.

## Coverage and CRAP

The narrowed run still prepares dependencies without UT/IT, verifies selected
classes without `-am`, separates Surefire and Failsafe selectors and requires
fresh non-skipped reports. It publishes the normal fresh UT/IT and changed-class
bytecode snapshot. Coverage and CRAP reuse that snapshot, never baseline data.
Full verification and global coverage/CRAP requirements remain separate gates.

The Commons Lang BitField scenario cannot seed a valid baseline while its full
suite has timezone failures. In that state the correct result is an explained
full-suite fallback. A passing synthetic Maven regression covers direct tests,
transitive consumers, forks, parameterized cases and an unrelated test excluded
from a subsequent compatible production change. No reduction is claimed for
Commons Lang without a successful full baseline.
