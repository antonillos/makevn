<p align="center">
  <img src="docs/assets/makevn-logo.svg" alt="makevn logo" width="180" /><br />
  <img src="docs/assets/makevn-wordmark.svg" alt="makevn" width="220" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Java-Maven-orange" alt="Java Maven" />
  <img src="https://img.shields.io/badge/Docker-supported-2496ed" alt="Docker supported" />
  <img src="https://img.shields.io/badge/Karate-supported-16a34a" alt="Karate supported" />
  <img src="https://img.shields.io/badge/agent-ready-2dd4bf" alt="Agent ready" />
  <a href="mcp/">
    <img src="https://img.shields.io/badge/MCP-server-7c3aed" alt="MCP Server" />
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="MIT License" />
  </a>
  <a href="https://github.com/antonillos/homebrew-tap">
    <img src="https://img.shields.io/badge/brew-antonillos%2Ftap%2Fmakevn-fbbf24" alt="Homebrew" />
  </a>
</p>

<p align="center"><em>Analyze a Java/Maven repository and run its build, tests, app, Docker services, coverage, and Karate E2E flows from the terminal.</em></p>

<p align="center">
  <a href="#install">Install</a> •
  <a href="#usage">Usage</a> •
  <a href="#verification">Verification</a> •
  <a href="#mcp">MCP</a> •
  <a href="#ai-agents">AI agents</a>
</p>

---

`makevn` is a terminal control plane for Java/Maven repositories. It inspects
the repository, detects the Java, Maven, Docker, Karate, and coverage setup, and
prepares safe commands for build, test, verification, application runs, and E2E
flows.

Think of it as a repository doctor and command runner for Java projects: the
agent or developer runs `makevn doctor`, then uses the generated context to run
the right workflow without opening an IDE or guessing repository scripts.

It does not overwrite an existing root `Makefile` or `GNUmakefile`.

## Install

Use the first available channel:

1. Homebrew on macOS.
2. asdf on WSL2, Linux, or managed workstations.
3. Release installer only when Homebrew and asdf are unavailable.

Do not build from source unless you are developing makevn itself.

### Homebrew

```bash
brew install antonillos/tap/makevn
```

The formula installs prebuilt release binaries for `makevn` and `makevn-mcp`.

### asdf

Recommended for WSL2 and Linux workstations managed with asdf:

```bash
asdf plugin add makevn https://github.com/antonillos/asdf-makevn.git
MAKEVN_VERSION="$(asdf latest makevn | sed -n '$p')"
asdf install makevn "${MAKEVN_VERSION}"
asdf set -u makevn "${MAKEVN_VERSION}"
asdf reshim makevn "${MAKEVN_VERSION}"
```

`asdf` 0.16+ uses `asdf set -u`, not `asdf global`.

### Agent fallback install

Use this only when Homebrew and asdf are unavailable:

```bash
curl -fsSL https://raw.githubusercontent.com/antonillos/makevn/main/packaging/install/install-release.sh | sh
```

### Source install

Only for makevn development from this repository:

```bash
./build-rust-dispatcher.sh
./install.sh --rust
~/.local/bin/makevn --help
```

## Usage

### Start in a Java Maven repo

```bash
makevn doctor
makevn test --name UserRepositoryTest
makevn verify
```

If `makevn doctor` reports missing, stale, or uninitialized makevn state, run:

```bash
makevn init
makevn doctor
```

Run against another repository:

```bash
makevn --repo "/path/to/java-repo" doctor
makevn --repo "/path/to/java-repo" verify-changes
```

### Optional Make integration

`init` always creates `.makevn/` without touching root makefiles.

If you also want `vn-*` make targets:

```bash
makevn make install
make -f .makevn/makevn.mk vn-doctor
```

### Run common commands

```bash
makevn compile
makevn test-compile
makevn compile-tests
makevn validate
makevn package
makevn build
makevn clean
makevn test
makevn test --name UserRepositoryTest
makevn test --name UserRepositoryTest,OrderRepositoryTest
makevn test --fast --name UserRepositoryTest
makevn format --apply
makevn checkstyle --module domain --verbose
makevn docker-up
makevn docker-down
makevn docker-ps
makevn docker-stats
makevn docker-ps-required
makevn docker-ps-required --compose karate
makevn docker-ps-required --wait-seconds 15
makevn karate-docker-up
makevn karate-docker-down
makevn karate-test
makevn karate-test --tag @smoke
makevn run-app-bg
makevn stop-app
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

Use `--tail` only for a human interactive log view. During a normal interactive
run, press `t` to tail the current managed log. Agents should prefer
non-interactive runs and generated logs.

Use `--compact` when you want agent-style output even in a TTY: no colors, no
interactive loader, full logs under `.makevn/logs/`, and only a compact summary
plus a short failure excerpt when needed. MCP tool calls use compact output by default.

## Verification

```bash
makevn verify-ut
makevn verify-ut-coverage
makevn verify-it
makevn verify-it-coverage
makevn verify
makevn verify-changes
makevn coverage
makevn coverage-changes
makevn pr-verify
```

| Command | What it does |
| ------- | ------------ |
| `verify-ut` | Runs unit-test-only verification |
| `verify-it` | Runs integration-test-only verification |
| `verify` | Runs combined verification and rejects UT/IT skip flags |
| `verify-changes` | Verifies changed production modules or modified tests |
| `coverage` | Checks the latest JaCoCo aggregate report against the repo threshold |
| `coverage-changes` | Checks incremental, per-changed-module, and overall JaCoCo coverage |
| `pr-verify` | Runs a local PR-style verification flow |

Changed-code coverage expects a coverage-producing command to run first:

```bash
makevn verify
makevn coverage
makevn verify-changes
makevn coverage-changes --threshold 90 --overall-threshold 95
```

## Make integration

The generated make include uses namespaced targets only, so it does not collide
with repo-owned targets such as `build`, `test`, or `run`.

```bash
make -f .makevn/makevn.mk vn-test NAME=UserRepositoryTest
make -f .makevn/makevn.mk vn-test NAMES="UserRepositoryTest,OrderRepositoryTest"
make -f .makevn/makevn.mk vn-verify-changes
make -f .makevn/makevn.mk vn-coverage
make -f .makevn/makevn.mk vn-coverage-changes
make -f .makevn/makevn.mk vn-pr-verify
```

## AI agents

Agents should treat `makevn` as the primary interface for Java/Maven work:

```bash
makevn doctor
makevn test --name SomeTest
makevn coverage
makevn verify-changes
makevn coverage-changes
```

Recommended agent behavior:

- run `makevn doctor` before initialization
- answer `makevn doctor` prompts with repository-specific values, or ask the human when the health URL cannot be confirmed
- choose the least invasive initialization mode
- preserve existing root makefiles
- use `makevn uninstall` for rollback
- use `verify-changes` for changed modules/tests
- use `coverage` for the latest aggregate report gate
- use `coverage-changes` after a coverage-producing run
- use `format`/`checkstyle` only when the repo declares a formatter/style plugin or `.makevn/config` sets explicit goals
- avoid `--tail` unless a human asks for interactive logs
- do not build makevn from source unless the human is developing makevn itself

`format` detects common Maven formatters such as Spotless, `fmt-maven-plugin`,
Revelc `formatter-maven-plugin`, Google Java Format through those plugins, and
custom formatter plugins declared in `pom.xml`. If a repo needs explicit goals,
set `MAKEVN_FORMAT_CHECK_GOAL`, `MAKEVN_FORMAT_APPLY_GOAL`, or
`MAKEVN_CHECKSTYLE_GOAL` in `.makevn/config`; `makevn` will not guess a default
goal when nothing is configured.

Agents should not call target-repository legacy helpers under `scripts/make/*`.
Those scripts can guide parity work, but runtime behavior must come from the
installed backend under `libexec/makevn/`.

## MCP

makevn ships an official [MCP](https://modelcontextprotocol.io) (Model Context
Protocol) server so AI agents in any MCP-compatible client (Claude Desktop,
Cursor, Windsurf, etc.) can run Java/Maven workflows directly.

The MCP server ships as the dedicated Rust `makevn-mcp` binary. It is
self-contained and has no Node.js dependency.

### Quick start

Add to your MCP client config:

```json
{
  "mcpServers": {
    "makevn": {
      "command": "makevn-mcp"
    }
  }
}
```

If `makevn-mcp` is not in PATH, use the full path (e.g. `/usr/local/bin/makevn-mcp`).

### Common MCP tools

| Tool | Description |
| ---- | ----------- |
| `makevn_doctor` | Inspect a Java/Maven repository |
| `makevn_init` | Initialize makevn in a repository |
| `makevn_test` | Run tests with optional name filter |
| `makevn_verify` | Full combined verification |
| `makevn_verify_changes` | Verify changed modules or modified tests |
| `makevn_coverage` | Check aggregate coverage |
| `makevn_coverage_changes` | Check changed-code coverage |
| `makevn_format` | Check or apply formatting |
| `makevn_checkstyle` | Run Checkstyle checks |
| `makevn_docker_up` | Start boot compose services |
| `makevn_docker_ps_required` | Validate required compose services |

MCP tools accept a `repo` argument to target a specific repository path. Most
tools accept `compact` for agent-friendly output. See `mcp/README.md` for
OpenCode and Codex config examples.

## What gets installed

```text
bin/makevn
bin/makevn-mcp
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
- [Agent install](docs/agent-install.md)
- [Agents](docs/agents.md)
- [CLI contract](docs/cli-contract.md)
- [Backend contract](docs/backend-contract.md)
- [Integration](docs/integration.md)
- [Distribution](docs/distribution.md)

## License

MIT. See [LICENSE](LICENSE).
