# Automatic impact for contracts and shared resources

Focused planning must not guess ownership from company, artifact, schema or module
names. It uses the current local, unconditional reactor and POM relationships.
**No hand-maintained impact JSON is required.**

## Generated state, not maintained policy

`init`, initialized-repository `doctor`, `verify-changes-preview` and `verify-changes` refresh
`.makevn/impact.json` automatically. It describes the detected Maven base and
shared-resource strategy. Before initialization, doctor remains inspection-only
and defers state creation until init. If Python 3 is unavailable, init/doctor visibly defer
impact generation without failing adoption; focused planning already requires
Python and generates state once available. It is disposable inspection state: never edit/version
it, and never rely on its contents to select tests. Every preview/run recomputes
ownership from current POMs; added/removed modules cannot leave a stale owner list.

For a plain root aggregator (`packaging=pom`, unconditional modules, no root-level
executable/test sources), shared root `src/test/resources` can affect any declared
module. Without a proven narrower scope, makevn conservatively selects **every
reactor module's complete suite**, including aggregators with verification goals.
The plan displays those owners and explains this potentially expensive scope.
Preparation still skips UT/IT; owner verification still runs without `-am`.
This is a classified shared-test-resource scope, not a silent switch to exhaustive.

This default is **Maven module verification only**. It does not execute or prove
external Karate/E2E checks, root build lifecycle checks, global coverage or global
CRAP gates. Keep those workflows separately. Generated state never asserts that
no external consumers exist. Missing/conditional modules, root source owners,
linked inputs or otherwise ambiguous models still require `--exhaustive`.

## Nested contract POMs

A nested leaf POM can be focused when its only semantic changes are literal
`*version` property values, used as direct dependency versions. Preparation includes
the contract; verification selects its complete suite and the reverse transitive
closure of local consumers, including local POM inheritance. DependencyManagement
alone does not establish consumption. Profile dependency declarations are
conservatively included rather than guessed inactive.

Static coordinate resolution supports local parent inheritance, local properties
and `project`/`pom` groupId, artifactId and version. Missing modules, duplicate
coordinates, unresolved/profile-dependent coordinate properties, changed model
structure and unclassified property uses require exhaustive verification. This is
not an effective-POM evaluator: it does not download parents, activate settings or
execute repository code. Existing full CI gates remain mandatory.

A matching `maven-dependency-plugin` artifactItem version is also supported. Explicit
output directories must stay in the contract module or have a safe shared-resource
scope. Root test-resource outputs use the same automatic conservative strategy,
without requiring a configuration file. Other plugin/property uses remain unsupported.

## Optional advanced narrowing

Repositories that explicitly want a smaller shared-resource plan can optionally
provide `makevn-impact.json` at the **Git root**. This is an authored override,
**not the generated `.makevn/impact.json` and not required for normal use**.

```json
{
  "version": 1,
  "sharedResources": [
    {
      "path": "workspace/src/test/resources/shared-events",
      "modules": ["adapter", "runner"],
      "externalChecks": []
    }
  ]
}
```

- `path`: literal repository-relative prefix under Maven-root `src/test/resources`;
  no globs, traversal, absolute paths or links. Matches use path boundaries.
- `modules`: nonempty list of all Maven test consumers, relative to the Maven root;
  declared non-aggregator leaf modules. The maintainer, not makevn, takes
  responsibility for narrowing. A generator alone does not prove consumers.
- `externalChecks`: required array of descriptions of required non-Maven checks.
  A nonempty list blocks focused planning and names them. Exhaustive verifies
  Maven only; run the external checks separately. Descriptions are never executed.
  An empty array is an explicit maintainer declaration, not an automatic guess.
- Overlapping explicit mappings union owners, never override an external blocker.
  Unmapped root test resources retain the automatic full-reactor suite scope.
- Invalid declarations fail closed and are never silently replaced. A versioned
  policy-file change itself still requires exhaustive verification.

Both CLI and MCP use the same backend planner and expose scope limitations.
Focused evidence fingerprints POMs, optional declarations and shared inputs,
including Git-ignored binary fixtures. Editing inputs invalidates the previous
coverage/CRAP evidence; editing generated state cannot narrow or invalidate it.
Contract/fixture-only changes without changed production Java classes can yield
**not applicable** incremental coverage/CRAP after successful verification, never
an overall gate pass.

## Prepared-input freshness

Focused verification records input hashes before preparation and checks them again
before any owner suite runs. Maven may rewrite shared root test fixtures during
dependency preparation. Those fixture-only changes become the test baseline only
when the statically declared reactor is supported and every consumer module will
run its complete Maven suite. Preparation execution data is discarded.

Production source, POM, configuration or comparison changes are not accepted by
this checkpoint. Any hashed input change after the checkpoint still invalidates
the evidence; diagnostics list changed paths rather than assuming a manual edit.
This does not prove external/E2E checks or narrow shared-resource ownership.
