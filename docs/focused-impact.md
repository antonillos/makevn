# Declared impact for contracts and shared resources

Focused planning must not guess ownership from company, artifact, schema or module
names. It uses local, unconditional reactor declarations and POM relationships.
There is no implicit `boot` owner and no automatic exclusion of Avro/YAML fixtures.

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

A matching `maven-dependency-plugin` artifactItem version is also supported. Its
explicit output directories must stay in the contract module or have a declared
shared-resource scope. Other plugin/property uses remain unsupported.

## Shared test resource declarations

Place `makevn-impact.json` at the **Git repository root**. This is an optional,
repository-owned declaration, not generated configuration or a shell script.
Example with neutral names (replace every path/module with your own reactor):

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

- `path` is a literal, repository-relative directory/file prefix under the
  **Maven-root** `src/test/resources`; no globs, absolute paths, parent traversal
  or linked inputs. Matching uses path boundaries, not string-prefix guessing.
- `modules` is a nonempty list of **all Maven test consumers**, relative to the
  Maven root. Each must be a declared, non-aggregator leaf module. Their **full
  suites** run, not only tests inferred from source imports. The declaration is
  an explicit responsibility of the repository maintainer, not proof discovered
  by makevn. Listing a generator alone is insufficient.
- `externalChecks` is a required array of descriptions of required checks outside
  this Maven reactor. Empty means the maintainer declares no additional external
  checks for this scope. If nonempty, focused planning **stops and names them**:
  exhaustive verifies Maven only; those external checks must run separately.
  Descriptions are never executed as commands. Do not leave this empty merely to
  bypass shared Karate/E2E infrastructure impact.
- Overlapping mappings union their consumers; no mapping can subtract tests or
  override an external-check requirement.
- Deleted fixtures are matched too. Unmapped root resources and unrelated build
  changes still fail closed. The file cannot hide production Java or POM changes.
- A versioned change to `makevn-impact.json` itself is a verification-policy
  change requiring exhaustive verification; it is not silently ignored.

Review declarations alongside build/test configuration. Both CLI and MCP use the
same planner and report missing/invalid scope or external-check blockers. No MCP
server changes or company-specific rules are needed.

Focused coverage evidence fingerprints this declaration and declared shared
inputs (including non-Java/binary fixtures). Editing them invalidates the previous
run; rerun verification. Contract/fixture-only changes without changed production
Java classes can yield **not applicable** coverage/CRAP after successful focused
verification, not a global gate pass.
