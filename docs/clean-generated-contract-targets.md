# Clean Generated Contract Targets

## Problem

Modules with code generation plugins (Avro, OpenAPI, Protobuf, etc.) can accumulate
stale generated sources in `target/` subdirectories after a contract version bump.
Old `.java` files persist from previous generations, causing class redefinition
errors and confusing compilation failures.

**Symptom**: `makevn test` / `makevn verify` / `makevn verify-changes` fail with
`duplicate class` errors in generated source packages (e.g., `GroupEventEnvelopeV3`
defined twice).

**Root cause**: The Maven `generate-sources` phase does not clean its output
directory before regenerating. When a contract artifact version changes, files
from the old version remain alongside new files, and both get compiled.

## Scope

Any module that uses a Maven plugin to generate Java sources from external
contracts (schemas, API specs, proto definitions, etc.) is affected.

## Detection Strategy

Parse each module's `pom.xml` to detect known generated-contract plugins and
extract their configured output directories. Four plugin families are detected
explicitly:

| Plugin artifactId | Config key read | Default output | Also clean |
|---|---|---|---|
| `avro-maven-plugin` | `<outputDirectory>` | `target/generated-sources/avro/` | `target/avro/` |
| `maven-dependency-plugin` (goal `unpack`) | `<artifactItem>/<outputDirectory>` | per-artifact | `target/dependency-maven-plugin-markers/` |
| `openapi-generator-maven-plugin` | `<output>` | `target/generated-sources/openapi/` | — |
| `protobuf-maven-plugin` | `<outputDirectory>` | `target/generated-sources/protobuf/` | — |

In addition, `target/generated-sources/` is always cleaned as a catch-all for
any other code generator not explicitly mapped, and for annotation processors
(Lombok, MapStruct, etc.) whose output would otherwise accumulate.

## Safety Constraints

- **Only paths that resolve to a `target/` subdirectory** (at any module
  level) are cleaned automatically. The `target/` directory is build output
  (always in `.gitignore`) and safe to delete.
- If a plugin's configured `outputDirectory` contains unresolved Maven
  properties (e.g., `${project.build.directory}/custom-gen`), the path
  cannot be resolved safely and is **skipped**. During `makevn init`, such
  paths are auto-detected and written to `MAKEVN_GENERATED_CONTRACT_CLEAN_DIRS`
  in `.makevn/config`. Edit that value with the resolved path if needed.
- The clean runs before the Maven invocation but after all CLI argument
  parsing. It does not affect the Maven command itself — it only removes
  stale files so the `generate-sources` phase starts from a clean state.

## Usage

### Clean with generated sources cleanup

```bash
makevn clean --clean-generated-contract-targets
```

This runs `mvn clean` and then removes stale generated source directories
detected from code-generation plugins.

### MCP tool

```json
{
  "tool": "clean",
  "arguments": {
    "clean-generated-contract-targets": true
  }
}
```

### Post-failure hint in test

When `makevn test` fails with compilation errors related to generated sources
(e.g., `cannot find symbol`, `duplicate class`, `package does not exist`
referencing `generated-sources`), a hint is displayed:

```
Hint: detected stale generated sources error. Run:
  makevn clean --clean-generated-contract-targets
```

## Implementation

### Shell functions in `generated_contract.sh`

```bash
makevn_detect_generated_contract_output_dirs(maven_base_path)
  # Perl: parses POMs, returns newline-separated "module:path" entries

makevn_clean_generated_contract_targets(repo_root, maven_base_path)
  # Calls detect, validates paths (must be under target/), rm -rf each

makevn_should_clean_generated_contract_targets()
  # Returns true only if --clean-generated-contract-targets flag was passed

makevn_clean_generated_contract_if_needed(repo_root)
  # Combines should + detect + clean

makevn_hint_stale_generated_sources_if_needed(log_file)
  # Checks log for stale generated sources errors and prints hint
```

### Integration points

| Command | Behavior |
|---|---|
| `cmd_clean` | After `mvn clean`, calls `makevn_clean_generated_contract_if_needed` if flag is set |
| `cmd_test` | Shows hint on failure if log contains stale generated sources errors |
| `makevn_run_selected_test` | Shows hint on failure if log contains stale generated sources errors |

## Future refinements

- Add `target/generated-test-sources/` to the catch-all if test-scoped
  generators also prove problematic.
- Add more plugins to the explicit detection list as users report them.
