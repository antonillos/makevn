# AGENTS.md

This repository's agent-facing documentation lives in:

- `docs/agents.md`
- `skills/makevn/SKILL.md`
- `docs/repo-sweep.md`

For work in this repository:

- Open pull requests against `develop` by default. Never open a pull request targeting `main` unless the user explicitly authorizes `main` as the base for that specific request; do not infer authorization from previous requests or release workflows. Verify the base branch before creating a pull request.
- Keep tests and test-only helpers in separate files from production code where practical. When working in a file with inline tests or test-only helpers, migrate them to its corresponding test file where feasible, preserving test names and private access. For Rust unit tests, use sibling `*_test.rs` files included as `#[cfg(test)]` modules with `#[path = "..."]`; production files should contain only the module inclusion, not test functions or test-only helpers.
- Prefer `fff` MCP tools for file and code search when available.
- Prefer `rtk` wrappers for shell commands when available.
- Use `makevn` as the public terminal contract for Java and Maven work.
- Run `makevn doctor` before init, adoption, or verification decisions.
- If `makevn doctor` reports `supported` and the repository is not initialized, run `makevn init` before continuing with adoption or verification work. If support is `unsupported`, report that no Maven project was detected and stop adoption/verification; do not run `init` or `refresh`.
- Do not assume Docker is required for `makevn verify` just because a repository has a root `docker-compose.yml`; use doctor, config, profile, and test-compose signals.
- Prefer `repo-sweep quick` for real-repository validation, and inspect classifications before deciding whether a failure is a product bug.
- For multi-step deterministic workflows (boot verify, changes validation, multi-test, karate E2E), prefer `composite_run` MCP tool to avoid ~34k context cost per subagent. Use subagent Tasks only when the workflow needs decisions (e.g., `adaptive-test`).
- The CRAP ratchet is mandatory for every change and must never be exceeded. CRAP calculation and authoritative verification must run in CI through a pull request because local results are inconsistent. Create or update the pull request against `develop` by default and require the CI CRAP gate to pass before merging. Local runs of `tools/crap/rust-crap.sh`, `tools/crap/shell-crap.sh`, and `tools/crap/run.sh` are optional diagnostics, not a prerequisite for creating or updating a pull request and not a substitute for CI verification.
- The same CI CRAP verification is required for commits that address Codex Reviewer comments; review fixes are not exempt from the ratchet.
- The internal CRAP ratchet covers authored production Rust and Bash. Do not include generated JavaScript bundles or JavaScript test files unless authored production JavaScript is introduced.
