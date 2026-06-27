# AGENTS.md

This repository's agent-facing documentation lives in:

- `docs/agents.md`
- `skills/makevn/SKILL.md`
- `docs/repo-sweep.md`

For work in this repository:

- Prefer `fff` MCP tools for file and code search when available.
- Prefer `rtk` wrappers for shell commands when available.
- Use `makevn` as the public terminal contract for Java and Maven work.
- Run `makevn doctor` before init, adoption, or verification decisions.
- If `makevn doctor` reports that the repository is not initialized, run `makevn init` before continuing with adoption or verification work.
- Do not assume Docker is required for `makevn verify` just because a repository has a root `docker-compose.yml`; use doctor, config, profile, and test-compose signals.
- Prefer `repo-sweep quick` for real-repository validation, and inspect classifications before deciding whether a failure is a product bug.
- For multi-step deterministic workflows (boot verify, changes validation, multi-test, karate E2E), prefer `composite_run` MCP tool to avoid ~34k context cost per subagent. Use subagent Tasks only when the workflow needs decisions (e.g., `adaptive-test`).
