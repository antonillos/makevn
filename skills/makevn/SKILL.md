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

In OpenCode specifically, the agent should treat `makevn` as the terminal contract for the repository. It does not need to invent IDE run configurations or rely on editor-specific behavior. When structured output exists, prefer `--json` over parsing prose.

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

## Command Reference

```bash
makevn doctor
makevn init --mode standalone
makevn init --mode make-include
makevn init --mode make-bootstrap
makevn uninstall
makevn build
makevn test
makevn verify-ut
makevn verify-it
makevn verify
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

For the frozen public and internal contracts, see:

- `docs/cli-contract.md`
- `docs/backend-contract.md`

## Make Integration

Shared targets are namespaced to avoid collisions:

- `vn-doctor`
- `vn-build`
- `vn-test`
- `vn-verify`
- `vn-run`
- `vn-jdk-current`
- `vn-jdk-list`

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
