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
  <a href="https://github.com/antonillos/makevn/actions/workflows/verify.yml">
    <img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fantonillos.github.io%2Fmakevn%2Fcrap-badge.json" alt="CRAP warnings" />
  </a>
</p>

<p align="center"><strong>Run Java/Maven builds, tests, apps, Docker services, coverage, and E2E workflows with one CLI.</strong></p>

`makevn` detects the repository's Java, Maven, Docker, Karate, and coverage setup
so developers and AI agents can run the right workflow from the terminal.

## See it in action

Operational demos are recorded from a matched CLI/MCP source build; installation
shows the published distribution. See [recording status and regeneration](docs/demo/README.md)
for pending recordings; an older GIF is not evidence of the current output.

### Developer

![Developer workflow: inspect a Java/Maven repository, run a targeted test, and verify it](docs/assets/makevn-developer.gif)

```bash
makevn doctor
makevn init # only when doctor recommends it
makevn test --name CalculatorTest
makevn verify
```

### Live telemetry

![makevn dashboard with live CPU and RAM telemetry](docs/assets/makevn-telemetry.gif)

```bash
makevn clean compile package
```

### Tail logs

![makevn tail mode showing Maven logs while the command runs](docs/assets/makevn-tail.gif)

```bash
makevn compile --tail
```

### Docker verification

Refresh pending: a running Docker daemon is required. [Previous recording](docs/assets/makevn-verify-docker.gif).

```bash
makevn docker-up docker-ps-required --wait-seconds 30 verify
makevn docker-down
```

### Codex agent

Refresh pending: Codex’s configured model is unavailable to its CLI account. [Previous recording](docs/assets/makevn-agent.gif).

```bash
codex exec 'Use makevn MCP: doctor, init if recommended, then composite_run with clean, compile, package.'
```

### OpenCode agent

Refresh pending: OpenCode authentication needs renewal. [Previous recording](docs/assets/makevn-opencode.gif).

```bash
opencode run 'Use makevn MCP: doctor, init if recommended, then composite_run with clean, compile, package.'
```

### Changed-code verification and coverage

![Preview affected code, verify it, and check coverage](docs/assets/makevn-changes.gif)

```bash
makevn doctor --compact
makevn init # only when recommended
makevn verify-changes-preview
makevn verify-changes
makevn coverage-changes
```

### Direct MCP

![Real MCP calls and structured workflow results](docs/assets/makevn-mcp.gif)

The direct demo calls `doctor`, `init` and `composite_run` on `makevn-mcp`,
showing real structured results without enabling trace or requiring an agent account.

## Installation

### Homebrew

Refresh pending: a disposable Homebrew environment is required. [Previous recording](docs/assets/makevn-install-brew.gif).

```bash
brew install antonillos/tap/makevn
```

### asdf

![Install makevn with asdf](docs/assets/makevn-install-asdf.gif)

```bash
asdf plugin add makevn https://github.com/antonillos/asdf-makevn.git
MAKEVN_VERSION="$(asdf latest makevn | sed -n '$p')"
asdf install makevn "${MAKEVN_VERSION}"
asdf set -u makevn "${MAKEVN_VERSION}"
asdf reshim makevn "${MAKEVN_VERSION}"
```

Both channels install the `makevn` CLI and the `makevn-mcp` server. See
[installation options](docs/install.md) for the release installer and source
development instructions.

## Quick start

Run this from the root of a Java/Maven repository:

```bash
makevn doctor
makevn init       # only when doctor reports missing or stale makevn state
makevn test
makevn verify
```

Run against another repository:

```bash
makevn --repo "/path/to/java-repo" doctor
makevn --repo "/path/to/java-repo" verify-changes-preview
makevn --repo "/path/to/java-repo" verify-changes
```

## Commands

| Goal | Command |
| --- | --- |
| Inspect repository context | `makevn doctor` |
| Initialize local makevn state | `makevn init` |
| Run one or more tests | `makevn test --name UserRepositoryTest` |
| Build and verify | `makevn package`, `makevn verify` |
| Preview and verify changed modules or tests | `makevn verify-changes-preview`, `makevn verify-changes` |
| Check aggregate or changed-code coverage | `makevn coverage`, `makevn coverage-changes` |
| Analyze Java CRAP from an existing JaCoCo XML report | `makevn crap` |
| Analyze CRAP only for changed Java methods | `makevn crap-changes [--base REF]` |
| Start and inspect Docker services | `makevn docker-up`, `makevn docker-ps-required` |
| Run Karate E2E flows | `makevn karate-test`, `makevn karate-all` |
| Run the application | `makevn run-app`, `makevn run-app-bg` |

Commands can be chained:

```bash
makevn clean verify-it
```

## AI agents and MCP

Agents use the same `makevn` commands as developers. The included MCP server
also exposes typed tools such as `doctor`, `clean`, `compile`, `package`,
`verify_changes_preview`, and `verify_changes`, so clients can call them
directly when they support MCP.

```json
{
  "mcpServers": {
    "makevn": {
      "command": "makevn-mcp"
    }
  }
}
```

See [AI agent use](docs/agents.md) and the [MCP guide](mcp/README.md) for the
full agent workflow and client configuration.
MCP command echoes (`→ exec ...`) are hidden by default: omit `trace` or use
`trace: false`; use `trace: true` only if the human explicitly asks to see
the exact executed command, never for routine runs or failure diagnosis. Final results,
errors, and the auxiliary `durationMs` / `exitCode` / `tool` JSON stay visible.
See [trace control](mcp/README.md#command-trace-control) for workflow overrides
and direct CLI behavior.

When tests fail formatting validation, agents should run `makevn format --apply`
and rerun the original test, never disable the formatter. MCP recovery uses
`makevn_format` with `apply: true`.
See [formatting recovery for agents](docs/agents.md#formatting-failure-recovery-for-ai-agents).

## Standalone operation

Use the public CLI or MCP tools; repository Makefiles are not an execution contract.
There is no automatic migration or cleanup of old Make integrations.

## Documentation

- [Changelog / releases](https://github.com/antonillos/makevn/releases)
- [Install](docs/install.md)
- [Agent install](docs/agent-install.md)
- [AI agents](docs/agents.md)
- [CLI contract](docs/cli-contract.md)
- [Backend contract](docs/backend-contract.md)
- [Integration](docs/integration.md)
- [Distribution](docs/distribution.md)
- [Internal CRAP ratchet](tools/crap/README.md)

## License

MIT. See [LICENSE](LICENSE).

### Redundant MCP success timings

Without `trace` (or with `trace: false`), MCP also omits standalone success
timing lines such as `[ok] 1m 06s`: the always-visible `durationMs` / `exitCode`
JSON already provides that information. `trace: true` retains these lines for
explicit diagnostics. This applies to ordinary tools and individual
composite/parallel steps, following the same trace inheritance and overrides.
Meaningful results (including JSON), failure diagnostics and workflow summaries
remain visible. Log paths are provided in JSON `logPaths` instead of standalone
`[..] makevn ... | log: ...` headers. CLI output and managed logs are unchanged.
Do not enable trace merely to obtain status or duration; use the JSON metadata.

### MCP log paths in JSON

MCP moves standalone `[..] makevn ... | log: ...` headers into the always-visible
JSON metadata field `logPaths` (an array of unique paths in encounter order).
For composite/parallel workflows, each step has its own `logPaths`. An empty
array means no log header was reported, not that no logs exist. This applies
with either trace setting; `trace: true` still shows command echoes and success
timings. Normal results and failure diagnostics are untouched; CLI headers and
managed log files are unchanged. Paths keep their original form, typically
relative to the target repository, not the MCP server's working directory.

```json
{"durationMs": 6739, "exitCode": 0, "tool": "test", "logPaths": [".makevn/logs/test-SampleTest.log"]}
```
