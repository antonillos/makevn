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
</p>

<p align="center"><strong>Run Java/Maven builds, tests, apps, Docker services, coverage, and E2E workflows with one CLI.</strong></p>

`makevn` detects the repository's Java, Maven, Docker, Karate, and coverage setup
so developers and AI agents can run the right workflow from the terminal.

## See it in action

### Developer

![Developer workflow: inspect a Java/Maven repository, run a targeted test, and verify it](docs/assets/makevn-developer.gif)

```bash
makevn doctor
makevn test --name UserRepositoryTest
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

![makevn Docker verification with required service check](docs/assets/makevn-verify-docker.gif)

```bash
makevn docker-up docker-ps-required verify
```

### AI agent

![AI agent workflow using the makevn MCP server to run doctor, clean, compile, and package](docs/assets/makevn-agent.gif)

```bash
doctor
clean
compile
package
```

## Installation

### Homebrew

![Install makevn with Homebrew](docs/assets/makevn-install-brew.gif)

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
makevn --repo "/path/to/java-repo" verify-changes
```

## Commands

| Goal | Command |
| --- | --- |
| Inspect repository context | `makevn doctor` |
| Initialize local makevn state | `makevn init` |
| Run one or more tests | `makevn test --name UserRepositoryTest` |
| Build and verify | `makevn package`, `makevn verify` |
| Verify changed modules or tests | `makevn verify-changes` |
| Check aggregate or changed-code coverage | `makevn coverage`, `makevn coverage-changes` |
| Start and inspect Docker services | `makevn docker-up`, `makevn docker-ps-required` |
| Run Karate E2E flows | `makevn karate-test`, `makevn karate-all` |
| Run the application | `makevn run-app`, `makevn run-app-bg` |

Commands can be chained:

```bash
makevn clean verify-it
```

## AI agents and MCP

Agents use the same `makevn` commands as developers. The included MCP server
also exposes typed tools such as `doctor`, `clean`, `compile`, `package`, and
`verify_changes`.

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

## Optional Make integration

`makevn init` does not touch root makefiles. Install namespaced `vn-*` targets
only when you want them:

```bash
makevn make install
make -f .makevn/makevn.mk vn-doctor
```

## Documentation

- [Install](docs/install.md)
- [Agent install](docs/agent-install.md)
- [AI agents](docs/agents.md)
- [CLI contract](docs/cli-contract.md)
- [Backend contract](docs/backend-contract.md)
- [Integration](docs/integration.md)
- [Distribution](docs/distribution.md)

## License

MIT. See [LICENSE](LICENSE).
