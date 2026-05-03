# Philosophy

## Java + Maven Already Define the Workflow

If a repository is already Java and Maven based, the core local workflow already exists.

The build, test, verify, and packaging model is encoded in:

- `pom.xml`
- module structure
- plugin configuration
- repository-local toolchain signals such as `.tool-versions`

An IDE may provide convenient buttons, but those buttons normally end up running the same underlying commands.

`makevn` starts from that premise.

## The IDE Should Not Be the Contract

When day-to-day execution depends on hidden IDE setup, teams inherit several problems:

- harder onboarding
- inconsistent local behavior
- difficulty reproducing a failing run in CI or another machine
- weak support for terminal-first agents

`makevn` tries to make the terminal contract explicit instead.

## Terminal-First Helps Humans and Agents

For people:

- commands are inspectable
- behavior is reproducible
- setup is easier to explain

For AI agents:

- they only need a stable command surface
- they do not need editor-specific knowledge
- they can operate safely inside environments like OpenCode
- they benefit from structured output instead of parsing rich prose or Markdown

The intended model is simple:

- inspect the repository
- resolve the correct Java context
- run explicit commands
- avoid inventing IDE instructions unless the user explicitly asks for them

The intended product shape is also simple:

- Rust should own public CLI UX
- shell should own repository-aware execution
- the binary should be usable directly by humans and agents
- the skill should teach workflow policy rather than acting as a mandatory runtime layer

## Make Is Optional, Not Mandatory

`makevn` is not trying to force a root `Makefile` into every repository.

Instead it keeps initialization and Make adoption separate:

- `makevn init`
- `makevn make install`
- `makevn make uninstall`

This keeps the core path small for agents while still allowing `make`-based adoption where useful.

## Small Public Contract

The public contract should stay small and explainable:

- `makevn doctor`
- `makevn init`
- `makevn make install`
- `makevn make uninstall`
- `makevn uninstall`
- `makevn build`
- `makevn test`
- `makevn verify`
- `makevn exec -- ...`

That contract can grow, but it should remain grounded in commands that are already natural for Java Maven repositories.

As the CLI evolves, the default output should remain human-readable text while every public command gains optional `--json` output for automation and AI-agent use.

## Success Condition

`makevn` is succeeding if a Java Maven repository can be worked on locally and by AI agents using explicit terminal commands, without relying on opaque IDE behavior, and without requiring agents to parse fragile human-oriented output.
