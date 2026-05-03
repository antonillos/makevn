---
name: makevn
description: >-
  Terminal contract for Java/Maven work. Use this skill whenever working in any
  Java/Maven repository: running builds, tests, or verifications. Run makevn
  doctor first, avoid IDE-specific instructions, and verify changes with makevn
  test, makevn verify-ut, makevn verify-it, or makevn verify as appropriate.
---

# makevn Skill

Use this skill when the user wants to standardize local Java Maven workflows, resolve JDK context automatically, integrate with `make` safely, or add/remove `makevn` from a repository.

## What `makevn` Is

`makevn` is a terminal-first CLI for Java Maven repositories.

Its core premise is that if a repository already uses Maven, local build and test workflows should not require IDE-specific execution knowledge. The agent should be able to operate the repository from the terminal by applying the correct Java context.

The intended product direction is that `makevn` should be usable by agents as a normal installed binary. The skill should improve decision making and safety, not act as a required runtime layer.

It provides:

- repository inspection with `makevn doctor`
- safe initialization with `makevn init`
- transparent cleanup with `makevn uninstall`
- context-aware command execution using JDK resolution from `.tool-versions`
- optional `make` integration through namespaced `vn-*` targets
- a path toward structured `--json` output across the public command surface

## Safety Rules

1. Run `makevn doctor` before recommending `init`.
2. Never overwrite an existing `Makefile` or `GNUmakefile`.
3. Prefer `make-include` when a repo already has a make entrypoint.
4. Prefer `standalone` when the user wants the lowest-risk adoption path.
5. Use `make-bootstrap` only when the repo has no `Makefile` or `GNUmakefile` and the user explicitly wants `make` support.
6. Prefer `makevn uninstall` over manual cleanup.
7. When editing an existing makefile, use the explicit `--write-make-include` path only if the user asked for that integration.
8. Prefer `--json` when the command supports structured output and the agent needs reliable machine-readable data.
9. Avoid `--tail` unless the human explicitly asked for an interactive local log view.
10. Treat `makevn` subcommands as the primary public interface. Do not translate them into bare `make` targets. For Docker commands, run `makevn docker-up`, `makevn docker-down`, `makevn docker-ps`, or `makevn docker-ps-required`; do not run bare targets such as `make docker-up` or `make docker-ps-required`.
11. Treat Karate workflows the same way: run `makevn karate-docker-up`, `makevn karate-docker-down`, `makevn karate-test`, or `makevn karate-all` only when `makevn doctor` detects Karate files. Do not assume every repository has Karate.
12. Karate tests need the real app running. Use `makevn run-app-bg` before `makevn karate-test`, and always finish with `makevn stop-app`; `makevn karate-all` owns that lifecycle for the full flow.
13. Do not assume every repository uses `LOCAL_CONTAINERS`. Let `makevn doctor`, `.makevn/config`, the repository profile, or the user's exported `LOCAL_CONTAINERS` decide that behavior.
14. Do not hardcode company-specific application health URLs, path prefixes, package names, or repository paths. Let `makevn doctor` detect the health URL, or set `MAKEVN_APP_HEALTH_URL` in `.makevn/config` when the repository needs an explicit override.

## When A Command Counts As OK

Apply a Karpathy-style verification rule: do not treat a command as successful just because it printed plausible output or because the agent expected it to work.

A command is only OK when all of these are true:

1. the process exited with code `0`
2. the command reached the user-facing goal that was requested
3. there is a concrete verification signal, not just agent interpretation

Preferred verification signals:

- `makevn doctor`: the repo is recognized correctly and the reported mode/recommendation matches the repo shape
- `makevn init`: the expected files were created or updated, and a follow-up `makevn doctor` or `vn-doctor` confirms the integration works
- `makevn uninstall`: the managed assets are gone, and a follow-up check confirms cleanup
- `makevn build`, `makevn test`, `makevn verify`: the command exits `0` and no follow-up evidence contradicts the requested outcome
- selected workflow changes: rerun the smallest relevant validating command instead of assuming success from the edit alone

If the command exits `0` but the requested outcome is still not verified, do not report success yet. State what remains unverified and run the smallest reasonable check.

## Agent Workflow

1. Inspect the repo for:
   - `pom.xml`
   - `.tool-versions`
   - `Makefile`
   - `GNUmakefile`
   - `.makevn/`
2. Run `makevn doctor`.
3. Explain the recommended mode:
   - `standalone`
   - `make-include`
   - `make-bootstrap`
4. If the user wants installation, run `makevn init --mode ...`.
5. Validate the result with:
    - `makevn doctor`
    - or `make -f .makevn/makevn.mk vn-doctor`
6. If the user wants rollback, run `makevn uninstall`.

In OpenCode and Codex specifically, the agent should treat `makevn` as the terminal contract for the repository. It does not need to invent IDE run configurations or rely on editor-specific behavior. When structured output exists, prefer `--json` over parsing prose.

For Codex, keep changes surgical: inspect the repo first, run the smallest `makevn` command that proves the touched behavior, and do not edit `.makevn/` state manually when `makevn init`, `profile refresh`, or `uninstall` owns that behavior.

## Mode Selection

### Existing `Makefile` or `GNUmakefile`

Recommended:

- `makevn init --mode make-include`

Alternative:

- `makevn init --mode standalone`

### No Existing Make Entrypoint

Recommended:

- `makevn init --mode standalone`

Optional when the user wants `make`:

- `makevn init --mode make-bootstrap`

## Using `makevn exec` with Subdirectory Maven Projects

Some repositories keep the Maven project inside a subdirectory (e.g., `code/`) rather than at the repo root. `makevn doctor` reports this as `Maven base path`.

**Always check `Maven base path` in the `makevn doctor` output before composing any `makevn exec -- mvn ...` command.**

- If `Maven base path` equals the repo root → no `-f` flag needed.
- If `Maven base path` is a subdirectory (e.g., `.../repo/code`) → you **must** add `-f <relative-path>/pom.xml` to every `mvn` invocation, where `<relative-path>` is the subdirectory relative to the repo root.

Example: `makevn doctor` reports `Maven base path: /project/root/code`

```bash
# Wrong — Maven cannot find the reactor from the repo root
makevn exec -- mvn -pl application test

# Correct
makevn exec -- mvn -f code/pom.xml -pl application test
```

`makevn exec` always runs from the repo root, so the `-f` flag is the only safe way to point Maven at the correct `pom.xml` when the project lives in a subdirectory.

## Application Health URL

`makevn run-app-bg`, `makevn run-app`, and `makevn karate-all` wait for the application health URL before continuing. Agents must treat that URL as repository-specific configuration, not as a convention to guess from a company, framework, package, or artifact name.

Resolution order:

1. `MAKEVN_APP_HEALTH_URL` in `.makevn/config`
2. `MAKEVN_PROFILE_APP_HEALTH_URL` generated by `makevn doctor` / `makevn profile refresh`
3. generic Spring Boot inference from `application*.yml`, `application*.yaml`, or `application*.properties`

If the detected URL is wrong, update `.makevn/config` with `MAKEVN_APP_HEALTH_URL=...` or improve the generic detector in `makevn`; do not add hardcoded paths for a specific organization or repository.

## Command Reference

```bash
makevn doctor
makevn init --mode standalone
makevn init --mode make-include
makevn init --mode make-bootstrap
makevn uninstall
makevn profile refresh
makevn compile
makevn test-compile
makevn compile-tests
makevn validate
makevn package
makevn build
makevn clean
makevn test
makevn test --name MyTest
makevn test --name MyTest,OtherTest
makevn test --name MyTest --name OtherTest
makevn test --fast --name MyTest
makevn verify-ut
makevn verify-ut-coverage
makevn verify-it
makevn verify-it-coverage
makevn verify
makevn verify-changes
makevn coverage-changes
makevn pr-verify
makevn docker-up
makevn docker-down
makevn docker-ps
makevn docker-ps-required
makevn docker-ps-required --compose karate
makevn docker-up --tail
makevn docker-down --tail
makevn docker-ps --tail
makevn docker-ps-required --tail
makevn karate-docker-up
makevn karate-docker-down
makevn karate-docker-up --tail
makevn karate-docker-down --tail
makevn karate-test
makevn karate-test --tag @smoke
makevn karate-all
makevn run-app
makevn run-app-bg
makevn stop-app
makevn run
makevn exec -- mvn -v
makevn jdk current
makevn jdk list
```

When the repository is Java + Maven, prefer these commands over describing IDE actions.

Verification intent:

- use `makevn verify-ut` when the goal is unit-test-only verification
- use `makevn verify-it` when the goal is integration-test-only verification
- use `makevn verify` when the goal is the combined verification path
- do not turn `makevn verify` into a split workflow with skip flags; pick the explicit command instead

## Running Specific Tests

**Always prefer `makevn test --name` over `makevn exec -- mvn -Dtest=...`** when the goal is to run one or more specific test classes. This works for any test type — unit tests (UT) and integration tests (IT) alike.

```bash
# Run a single test class
makevn test --name SampleFeatureTogglesTest

# Run multiple test classes (two equivalent forms)
makevn test --name SampleFeatureTogglesTest,DeleteSampleItemsByVariantGroupCommandHandlerTest
makevn test --name SampleFeatureTogglesTest --name DeleteSampleItemsByVariantGroupCommandHandlerTest

# Skip compilation to run faster when sources have not changed
makevn test --fast --name SampleFeatureTogglesTest
```

Only fall back to `makevn exec -- mvn` when you need Maven flags or options that `makevn test` does not expose (e.g., `-pl` to target a specific module, or additional `-D` properties). In that case, check `Maven base path` in `makevn doctor` output first and add `-f <path>/pom.xml` if the Maven root is a subdirectory.

For the frozen public and internal contracts, see:

- `docs/cli-contract.md`
- `docs/backend-contract.md`

## Primary CLI vs Make Targets

For agents, the installed `makevn` binary is the default command surface.

Use direct `makevn` commands for normal repository work:

```bash
makevn doctor
makevn test --name MyTest
makevn verify-changes
makevn coverage-changes
makevn docker-up
makevn docker-down
makevn docker-ps
makevn docker-ps-required
makevn karate-test
makevn karate-test --tag @smoke
makevn run-app-bg
makevn stop-app
```

For Docker-backed commands (`docker-*`, `karate-docker-up`, and `karate-docker-down`), `--tail` is supported but remains a human-facing option. Agents should omit it unless the human asks for an interactive local view.

`makevn docker-ps-required` validates the boot compose by default. Use `makevn docker-ps-required --compose karate` when the required services belong to the detected Karate E2E compose. `makevn karate-docker-up` already waits for required Karate services to be running and healthy before it returns; agents should not add a separate immediate service check after `karate-docker-up` unless they explicitly need a standalone validation command.

Do not guess a root `make` target from a `makevn` subcommand name. This is invalid unless the repository itself defines such a target:

```bash
# Wrong
make docker-up
make docker-down
make docker-ps
make docker-ps-required
```

The optional make integration only exposes namespaced `vn-*` targets. For Docker commands, the make target name is always prefixed with `vn-`. Use these only when the user explicitly wants to exercise the make integration or the generated makefile itself:

```bash
make -f .makevn/makevn.mk vn-docker-up
make -f .makevn/makevn.mk vn-docker-down
make -f .makevn/makevn.mk vn-docker-ps
make -f .makevn/makevn.mk vn-docker-ps-required
make -f .makevn/makevn.mk vn-karate-test
make -f .makevn/makevn.mk vn-run-app-bg
make -f .makevn/makevn.mk vn-stop-app
```

## Make Integration

Shared targets are namespaced to avoid collisions:

- `vn-doctor`
- `vn-init`
- `vn-uninstall`
- `vn-profile-refresh`
- `vn-compile`
- `vn-test-compile`
- `vn-compile-tests`
- `vn-validate`
- `vn-package`
- `vn-build`
- `vn-clean`
- `vn-test`
- `vn-verify-ut`
- `vn-verify-ut-coverage`
- `vn-verify-it`
- `vn-verify-it-coverage`
- `vn-verify`
- `vn-verify-changes`
- `vn-coverage-changes`
- `vn-pr-verify`
- `vn-docker-up`
- `vn-docker-down`
- `vn-docker-ps`
- `vn-docker-ps-required`
- `vn-karate-docker-up`
- `vn-karate-docker-down`
- `vn-karate-test`
- `vn-karate-all`
- `vn-run-app`
- `vn-run-app-bg`
- `vn-stop-app`
- `vn-run`
- `vn-jdk-current`
- `vn-jdk-list`
- `vn-exec`

Use either:

```bash
make -f .makevn/makevn.mk vn-doctor
```

or an explicit include added by the user:

```make
include .makevn/makevn.mk
```

## Success Criteria

The skill has been applied correctly if:

- the repo keeps any existing `Makefile` or `GNUmakefile` compatible
- the user can run `makevn doctor`
- the selected mode matches the repo shape
- `makevn uninstall` cleanly removes the local integration
- the agent can use the installed `makevn` binary directly without inventing IDE-specific actions
