# Precise test selection within a Maven module

Focused verification can reuse an isolated test-to-class map for standard
single-module Java projects on JDK 17+. Missing or incompatible evidence retains
the complete owner suite and prints the reason. Reactors and generated Java
sources currently retain complete owner suites; cross-module narrowing is not
implemented.

## Capture once, reuse for compatible method-body edits

```bash
makevn verify-changes-preview --record-test-impact
makevn verify-changes --record-test-impact
# After a compatible production method-body edit:
makevn verify-changes-preview
makevn verify-changes coverage-changes crap-changes
```

For MCP pass `"record-test-impact": true` in both preview and verification.
The flag is opt-in because capture first runs the complete owner suite, then
runs one isolated verification per discovered test class. This is substantially
more expensive than ordinary focused verification. It needs an actual changed
production/test input selecting the complete root owner suite. A clean checkout
with no changed verification inputs does not seed evidence.

Capture requires a successful complete suite with fresh Surefire/Failsafe XML.
An entirely skipped test class, missing identity, failed test, interrupted run or
changing source/bytecode prevents publication. Parameterized and nested test
cases belong to their top-level class. Conventional plugin naming is enforced;
custom ownership falls back rather than guessing selectors.

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
optimistically. Transitive consumers and explicitly changed tests are included.
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
checksums. Do not hand-maintain it. A new capture retires the old map before tests.
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
