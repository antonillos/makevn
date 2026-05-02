# AI Agent Use

`makevn` ships a reusable skill under `skills/makevn/`.

The main idea is that a Java repository that already uses Maven should be operable from the terminal without IDE-specific knowledge. An agent should not need to understand IntelliJ buttons or editor run configurations if the repository can expose stable commands instead.

The intended product direction is that an agent should be able to use `makevn` as a normal installed binary, even without the skill. The skill should teach workflow policy and safety, not compensate for missing CLI behavior.

The skill is meant to teach agents to:

- inspect the repo before changing anything
- select the least invasive mode
- preserve compatibility with existing `Makefile` or `GNUmakefile`
- prefer `makevn uninstall` over heuristic cleanup
- operate the repository through terminal commands that also work from OpenCode
- treat `makevn` as the primary interface instead of relying on IDE actions
- prefer `--json` when it is available for the command being used
- avoid `--tail` unless a human explicitly requests an interactive local log view

Agent-facing commands should be stable without requiring agents to inspect or execute
repository-owned helper scripts. For changed-code workflows, agents should call the
public commands directly:

- `makevn verify-changes`
- `makevn coverage-changes`

Those commands are intentionally backed by `makevn`'s installed `libexec/makevn/`
runtime, not by a target repository's legacy `scripts/make/*` folder. Legacy
Makefile scripts can be useful examples when improving parity, but they must not be
part of the agent execution contract.

## Generic Workflow

1. Load the `makevn` skill in the agent environment.
2. Run `makevn doctor` in the target repo.
3. Recommend a mode.
4. Only then run `makevn init --mode ...` if the user wants installation.
5. Validate the result.
6. Use `makevn uninstall` to revert.

When JSON output exists for the command being used, agents should prefer it over parsing prose.

Today that guidance is forward-looking: public `--json` behavior is still part of the Rust transition rather than the currently published CLI surface.

## OpenCode Workflow

Inside OpenCode, the intended flow is:

1. inspect the repository shape
2. run `makevn doctor`
3. initialize only if needed
4. prefer `makevn ... --json` when machine-readable output is available and helps with decision making
5. run `makevn build`, `makevn test`, `makevn verify`, or `makevn exec -- ...`
6. avoid IDE-specific instructions unless the user explicitly asks for them

For pull-request or task-final verification, agents should prefer the smallest
command that proves the touched surface:

- changed modules/tests: `makevn verify-changes`
- changed-code coverage after a coverage-producing run: `makevn coverage-changes`
- full confidence pass: `makevn verify`

Because agent frameworks differ, this repository ships the skill contents and examples rather than hardcoding a single agent-specific installation path.

See also:

- `docs/cli-contract.md`
- `docs/backend-contract.md`
