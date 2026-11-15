# AGENTS.md

This repository's agent-facing documentation lives in:

- `docs/agents.md`
- `skills/makevn/SKILL.md`
- `docs/repo-sweep.md`

For work in this repository:

- Use `develop` as the integration branch for standalone pull requests and the trunk for stacked pull requests. For a coordinated series of changes, prefer a native GitHub stack: the bottom PR targets `develop`, and each higher PR targets the preceding PR's branch in the same repository. Verify the complete base chain reaches `develop` before creating or updating a stack. Never use `main` as a PR base or stack trunk unless the user explicitly authorizes it for that specific request; do not infer authorization from previous requests or release workflows.
- Keep each stack layer focused and independently reviewable. When merging is authorized and every included PR is ready, prefer merging the contiguous stack together through GitHub's stack merge operation or Smart Merge on its highest included PR. Validate the exact set of PRs that operation will merge. Refresh or rebase when changes, conflicts, GitHub requirements, or failed checks require it; avoid requesting redundant updates or reruns solely because a lower layer is about to merge. Passing checks must cover the current revisions, and changed revisions must receive fresh required checks.
- Keep tests and test-only helpers in separate files from production code where practical. When working in a file with inline tests or test-only helpers, migrate them to its corresponding test file where feasible, preserving test names and private access. For Rust unit tests, use sibling `*_test.rs` files included as `#[cfg(test)]` modules with `#[path = "..."]`; production files should contain only the module inclusion, not test functions or test-only helpers.
- Prefer `fff` MCP tools for file and code search when available.
- Prefer `rtk` wrappers for shell commands when available.
- Use `makevn` as the public terminal contract for Java and Maven work.
- Use MakeVN exclusively for all Docker operations, including read-only diagnostics, inspection, logs, networks, volumes, and lifecycle. Prefer MakeVN MCP tools, then supported `makevn` CLI commands. This overrides generic RTK preferences: never fall back to raw Docker, Compose, wrappers, scripts, SDKs, or the Docker API. If MakeVN lacks a capability, report it and stop the dependent action instead of working around it. MakeVN may invoke Docker internally.
- Run `makevn doctor` before init, adoption, or verification decisions.
- If `makevn doctor` reports `supported` and the repository is not initialized, run `makevn init` before continuing with adoption or verification work. If support is `unsupported`, report that no Maven project was detected and stop adoption/verification; do not run `init` or `refresh`.
- Do not assume Docker is required for `makevn verify` just because a repository has a root `docker-compose.yml`; use doctor, config, profile, and test-compose signals.
- Prefer `repo-sweep quick` for real-repository validation, and inspect classifications before deciding whether a failure is a product bug.
- For multi-step deterministic workflows (boot verify, changes validation, multi-test, karate E2E), prefer `composite_run` MCP tool to avoid ~34k context cost per subagent. Use subagent Tasks only when the workflow needs decisions (e.g., `adaptive-test`).
- The CRAP ratchet is mandatory for every change and must never be exceeded. CRAP calculation and authoritative verification must run in CI through a pull request because local results are inconsistent. Create or update a standalone PR against `develop` or a stack rooted at `develop`, and require the CI CRAP gate to pass for every included PR before merging. Local runs of `tools/crap/rust-crap.sh`, `tools/crap/shell-crap.sh`, and `tools/crap/run.sh` are optional diagnostics, not a prerequisite for creating or updating a pull request and not a substitute for CI verification.
- The same CI CRAP verification is required for commits that address Codex Reviewer comments; review fixes are not exempt from the ratchet.
- The internal CRAP ratchet covers authored production Rust and Bash. Do not include generated JavaScript bundles or JavaScript test files unless authored production JavaScript is introduced.
