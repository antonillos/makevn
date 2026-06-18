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

## Activation

### Automatic (default)

When a module has any of the detected plugins in its POM, the stale-target
directories for that module are cleaned automatically before every
`test` / `verify` / `verify-ut` / `verify-it` / `verify-changes` run.

### Opt-out

Set in `.makevn/config`:

```bash
MAKEVN_CLEAN_GENERATED_CONTRACT_TARGETS=false
```

### CLI flag (override)

```
makevn test --clean-generated-contract-targets
makevn verify --clean-generated-contract-targets
makevn verify-changes --clean-generated-contract-targets
```

The flag overrides the config setting for a single invocation.

## Implementation Plan

### New files

| File | Content |
|---|---|
| `libexec/makevn/common/generated_contract.sh` | Detection, cleanup, and flag-checking shell functions + embedded Perl POM parser |

### Modified files

| File | Change |
|---|---|
| `libexec/makevn/common/common.sh` | `source` the new module |
| `libexec/makevn/common/core.sh` | `unset MAKEVN_CLEAN_GENERATED_CONTRACT_TARGETS` in `makevn_load_config` |
| `libexec/makevn/commands/maven.sh` | Call cleanup in `cmd_test`, `cmd_verify`, `cmd_verify_ut`, `cmd_verify_it`; parse `--clean-generated-contract-targets` flag |
| `libexec/makevn/commands/changes.sh` | Call cleanup in `cmd_verify_changes` |
| `libexec/makevn/common/java_maven.sh` | Call cleanup in `makevn_run_selected_test` |
| `libexec/makevn/cli.sh` | Help text for `--clean-generated-contract-targets` |
| `rust/dispatcher/src/main.rs` | Add flag to `command_option_takes_value` |
| `share/makevn/makevn.mk` | `MAKEVN_CLEAN_GENERATED_CONTRACT_TARGETS` variable in `vn-test` / `vn-verify` targets |
| `docs/cli-contract.md` | Document the flag |
| `skills/makevn/SKILL.md` | Document in failure triage |

## Functions

### Shell functions in `generated_contract.sh`

```bash
makevn_detect_generated_contract_output_dirs(maven_base_path)
  # Perl: parses POMs, returns newline-separated "module:path" entries

makevn_clean_generated_contract_targets(repo_root, maven_base_path)
  # Calls detect, validates paths (must be under target/), rm -rf each

makevn_should_clean_generated_contract_targets(repo_root)
  # Checks config and flag override

makevn_clean_generated_contract_if_needed(repo_root, maven_base_path)
  # Combines should + detect + clean

makevn_generated_contract_flag_override()
  # Sets MAKEVN_CLEAN_GENERATED_CONTRACT_TARGETS=true if --clean-generated-contract-targets was passed
```

### Perl POM parsing

Embedded in `makevn_detect_generated_contract_output_dirs`, iterates over
`find`-discovered `pom.xml` files (excluding `target/`), extracts plugin
configurations, and emits `module:path` pairs.

## Integration points

| Command | Where cleanup is called |
|---|---|
| `cmd_test` | After flag parsing, before `makevn_run_maven_goal` / `makevn_run_selected_test` |
| `cmd_verify` | After `makevn_reject_verify_skip_flags`, before `makevn_run_maven_goal` |
| `cmd_verify_ut` | After `makevn_reject_verify_skip_flags`, before `makevn_run_maven_goal` |
| `cmd_verify_it` | After docker preflight check, before `makevn_run_verify_it_goal` |
| `cmd_verify_changes` | After parent branch detection, before constructing Maven args |
| `makevn_run_selected_test` | At the start, before building Maven args |

## Future refinements

- Add `target/generated-test-sources/` to the catch-all if test-scoped
  generators also prove problematic.
- Add more plugins to the explicit detection list as users report them.
