<h1 align="center">
  <img src="docs/assets/makevn-logo.svg" alt="makevn logo" width="180" /><br />
  <img src="docs/assets/makevn-wordmark.svg" alt="makevn" width="220" />
</h1>

<p align="center">
  <img src="https://img.shields.io/badge/java-21%2B-orange" alt="Java 21+" />
  <img src="https://img.shields.io/badge/maven-workflows-blue" alt="Maven workflows" />
  <img src="https://img.shields.io/badge/agent-ready-2dd4bf" alt="Agent ready" />
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="MIT License" />
  </a>
</p>

<h3 align="center">
  Run Java Maven builds, tests, verification, and changed-code coverage from one terminal command.
</h3>

<p align="center">
  <a href="#install">Install</a> •
  <a href="#usage">Usage</a> •
  <a href="#verification">Verification</a> •
  <a href="#ai-agents">AI agents</a>
</p>

---

`makevn` gives Java/Maven repositories a stable command surface for humans and
AI agents. It resolves the local Java context, runs the normal Maven workflows,
and avoids relying on IDE run configurations or repo-specific helper scripts.

It does not overwrite an existing root `Makefile` or `GNUmakefile`.

## Install

From this repository:

```bash
./build-rust-dispatcher.sh
./install.sh --rust
~/.local/bin/makevn --help
```

To install the shell entrypoint explicitly:

```bash
./install.sh --shell
```

## Usage

### Start in a Java Maven repo

```bash
makevn doctor
makevn init --mode standalone
makevn test --name UserRepositoryTest
makevn verify
```

Run against another repository:

```bash
makevn --repo "/path/to/java-repo" doctor
makevn --repo "/path/to/java-repo" verify-changes
```

### Choose an initialization mode

| Mode | Use it when |
|------|-------------|
| `standalone` | You want `.makevn/` only, with no root makefile changes |
| `make-include` | The repo already has a makefile and you want optional `vn-*` targets |
| `make-bootstrap` | The repo has no makefile and you want a root make entrypoint |

For existing makefiles:

```bash
makevn init --mode make-include
make -f .makevn/makevn.mk vn-doctor
```

### Run common commands

```bash
makevn compile
makevn compile-tests
makevn validate
makevn package
makevn build
makevn clean
makevn test
makevn test --name UserRepositoryTest
makevn test --name UserRepositoryTest,OrderRepositoryTest
makevn test --fast --name UserRepositoryTest
makevn docker-up
makevn docker-down
makevn docker-ps
makevn docker-ps-required
makevn run
makevn exec -- mvn -v
makevn jdk current
makevn jdk list
```

Commands can be chained:

```bash
makevn clean verify-it
makevn --tail clean verify-it
```

Use `--tail` only for a human interactive log view. Agents should prefer
non-interactive runs and generated logs.

## Verification

```bash
makevn verify-ut
makevn verify-ut-coverage
makevn verify-it
makevn verify-it-coverage
makevn verify
makevn verify-changes
makevn coverage-changes
makevn pr-verify
```

| Command | What it does |
|---------|--------------|
| `verify-ut` | Runs unit-test-only verification |
| `verify-it` | Runs integration-test-only verification |
| `verify` | Runs combined verification and rejects UT/IT skip flags |
| `verify-changes` | Verifies changed production modules or modified tests |
| `coverage-changes` | Checks JaCoCo coverage for changed production code |
| `pr-verify` | Runs a local PR-style verification flow |

Changed-code coverage expects a coverage-producing command to run first:

```bash
makevn verify-changes
makevn coverage-changes --threshold 90
```

## Make integration

The generated make include uses namespaced targets only, so it does not collide
with repo-owned targets such as `build`, `test`, or `run`.

```bash
make -f .makevn/makevn.mk vn-test NAME=UserRepositoryTest
make -f .makevn/makevn.mk vn-test NAMES="UserRepositoryTest,OrderRepositoryTest"
make -f .makevn/makevn.mk vn-verify-changes
make -f .makevn/makevn.mk vn-coverage-changes
make -f .makevn/makevn.mk vn-pr-verify
```

## AI agents

Agents should treat `makevn` as the primary interface for Java/Maven work:

```bash
makevn doctor
makevn test --name SomeTest
makevn verify-changes
makevn coverage-changes
```

Recommended agent behavior:

- run `makevn doctor` before initialization
- choose the least invasive initialization mode
- preserve existing root makefiles
- use `makevn uninstall` for rollback
- use `verify-changes` for changed modules/tests
- use `coverage-changes` after a coverage-producing run
- avoid `--tail` unless a human asks for interactive logs

Agents should not call target-repository legacy helpers under `scripts/make/*`.
Those scripts can guide parity work, but runtime behavior must come from the
installed backend under `libexec/makevn/`.

## What gets installed

```text
bin/makevn
libexec/makevn/backend.sh
libexec/makevn/cli.sh
libexec/makevn/common.sh
libexec/makevn/commands/
libexec/makevn/common/
libexec/makevn/compat/
libexec/makevn/coverage/
libexec/makevn/docker/
libexec/makevn/jdk/
share/makevn/makevn.mk
share/makevn/skills/makevn/
```

Changed-code verification and coverage are self-contained in `libexec/makevn/`
so developers and agents get the same behavior across Java Maven repositories.

## Docs

- [Install](docs/install.md)
- [Agents](docs/agents.md)
- [CLI contract](docs/cli-contract.md)
- [Backend contract](docs/backend-contract.md)
- [Integration](docs/integration.md)
- [Distribution](docs/distribution.md)

## License

MIT. See [LICENSE](LICENSE).
