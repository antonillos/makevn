# Testcontainers repositories

MakeVN supports Maven tests that create their own containers through
[Testcontainers for Java](https://java.testcontainers.org/supported_docker_environment/).
An `org.testcontainers` declaration in a repository POM activates a conservative
engine prerequisite for test and verification commands. A Compose file is not
required. Detection uses local POM declarations, not remote effective parents;
custom dependency coordinates and externally inherited dependencies may not be
detected.

## Workflow

Run doctor and complete its recommended initialization and setup first. Use MCP
`doctor`, `init` and `doctor_configure` in MCP sessions. Then run `test`,
`verify_ut`, `verify_it` or `verify` for the requested scope. Testcontainers tests
can run under Surefire with ordinary `*Test`/`*Tests` names; the annotation does
not imply a separate Failsafe integration suite. Report fresh test evidence.

Before executing tests, MakeVN checks Docker engine access inside the managed
test execution. This also covers unit verification in repositories declaring
Testcontainers. Compilation, test compilation and packaging commands are not
guarded by this check. Repository-level detection can require Docker even for a
selected test that does not itself start containers.

Without Compose, do not run `docker_up`: the tests start and clean up their
declared containers. `docker_up` starts Compose services, not Docker Desktop or
another engine runtime. If a repository separately requires Compose services,
perform the normal `docker_ps_required` readiness gate and authorized startup
before tests. `LOCAL_CONTAINERS=TRUE` neither starts nor validates an engine.

## Docker endpoint selection

Explicit `DOCKER_HOST` takes precedence for the Java process. MakeVN preserves
TLS settings and all `TESTCONTAINERS_*` environment variables. With no explicit
host, MakeVN resolves `DOCKER_CONTEXT` or the current Docker CLI context and
forwards its local Unix endpoint as `DOCKER_HOST` for the test execution only.
This supports local runtimes whose socket is outside `/var/run/docker.sock`.
The parent environment, Docker configuration and repository configuration are
not changed. The CLI context override is removed from the child so its engine
probe uses the same host as Java.

Remote contexts are not automatically translated: configure explicit
`DOCKER_HOST` and any necessary TLS settings. MakeVN does not extract context
credentials. It does not translate `~/.testcontainers.properties`, custom
provider strategies or cloud configuration into Docker CLI credentials; the
engine prerequisite expects the documented environment/context configuration.
Runtime-specific `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` and
`TESTCONTAINERS_HOST_OVERRIDE` remain explicit user choices. MakeVN does not
disable Ryuk, create symlinks, start runtimes or change VM sharing settings.

## Failure diagnosis

Engine/context probes have a 15-second timeout per call. Failed prerequisites
stop before tests start and retain their diagnostics in the test command's
managed log and MCP result. Diagnose endpoint selection, runtime availability,
permissions and TLS before retrying. A passing probe establishes engine access;
image pulls, older Testcontainers client compatibility and application assertions
can still fail later and must be classified separately.

`docker_ps` propagates Docker query failures rather than reporting an empty
successful list. Even a successful empty list does not prove Java can connect to
Docker. Use the test execution's prerequisite result for that evidence. All
container diagnostics and lifecycle operations remain within MakeVN.
