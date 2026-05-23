# Repository Sweep

`test/repo-sweep/run.sh` is a development-only robustness harness for validating
makevn against real local repositories. It is not part of the installed product
contract.

The primary user is an automated agent. The script therefore produces a
deterministic report, explicit classifications, and an agent verdict.

## Usage

Run against one repository:

```bash
test/repo-sweep/run.sh --profile quick /path/to/java-repo
```

Run against a directory containing repositories:

```bash
test/repo-sweep/run.sh --profile full /path/to/repositories
```

Profiles:

- `quick`: MCP contract, `doctor`, `init`, JDK, Make integration, read-only Docker probes, and capability classification.
- `full`: `quick` plus Maven build/test/coverage command groups with bounded timeouts.
- `destructive`: `full` plus Docker/Karate lifecycle commands against temporary clones only.

## Safety

The sweep installs makevn into a temporary prefix, calls `makevn-mcp` through
JSON-RPC, clones each target repository into a temporary directory, and runs
mutable commands only on the clone.

Do not edit fixture repositories to make the sweep pass. Repository failures are
test signal, not remediation instructions.

## Reports

The script prints these paths at start and end:

- `summary.md`: human and agent readable outcome
- `results.tsv`: machine-readable command matrix
- `tools.json`: MCP tool listing captured for the run

The summary includes one verdict:

- `clean`: no actionable makevn issue detected by the selected profile
- `repo-or-environment-issues`: makevn reached target commands, but the repo or local environment failed
- `action-required`: fix makevn or the sweep harness before trusting the result

By default the process exits non-zero only for `product_bug` or `tooling_error`.
Set `MAKEVN_REPO_SWEEP_FAIL_ON_PRODUCT_BUG=0` for exploratory runs where the
outer automation must continue after the report is written.

## Classifications

- `product_bug`: parser, MCP mapping, command ordering, or makevn behavior defect
- `tooling_error`: sweep harness, clone, MCP transport, or temporary install failure
- `repo_failure`: makevn invoked the target command, but the repository command failed
- `environment_missing`: unresolved JDK, Maven, Docker, or local prerequisite
- `expected_unavailable`: formatter, Checkstyle, Karate, Docker compose, coverage, or PIT is not declared by the repo
- `slow_path`: intentionally skipped or bounded expensive work such as mutation testing
- `ok`: command completed successfully

## Cache Knobs

```bash
MAKEVN_REPO_SWEEP_CACHE_DIR=/tmp/makevn-sweep-cache \
MAKEVN_REPO_SWEEP_INSTALL_PREFIX=/tmp/makevn-sweep-install \
test/repo-sweep/run.sh --profile quick /path/to/repositories
```

Enable mutation only when explicitly needed:

```bash
MAKEVN_REPO_SWEEP_MUTATION=1 test/repo-sweep/run.sh --profile full /path/to/repositories
```
