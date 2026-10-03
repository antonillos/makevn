# makevn MCP

`makevn-mcp` is the dedicated Rust MCP server for makevn. It has no Node.js or
JavaScript runtime dependency.

## Installation

Install makevn first through Homebrew, asdf, or the fallback release installer.
See `docs/agent-install.md`.

## OpenCode Configuration

Use one of these global config files:

- `~/.config/opencode/opencode.json`
- `~/.config/opencode/opencode.jsonc`

Add this top-level `"mcp"` entry:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "makevn": {
      "type": "local",
      "command": ["makevn-mcp"],
      "enabled": true,
      "timeout": 900000
    }
  }
}
```

- `enabled: true` keeps the MCP server always active across sessions.
- `command` must be an array. Do not write `"command": "makevn-mcp"` in
  OpenCode config.
- `timeout: 900000` (15 min) is sufficient for synchronous tools. The `mutation`
  tool spawns in background and returns immediately.

The `makevn-mcp` binary must be in `PATH`, or use an absolute path:

```jsonc
"command": ["/path/to/makevn-mcp"]
```

Restart OpenCode after editing config. OpenCode reads MCP configuration when it
starts and does not hot-reload it.

## Codex Configuration

Use `~/.codex/config.toml` for global Codex config. Use `.codex/config.toml`
only for a trusted project.

Add this table:

```toml
[mcp_servers.makevn]
command = "makevn-mcp"
enabled = true
startup_timeout_sec = 20
tool_timeout_sec = 900
```

Or run:

```bash
codex mcp add makevn -- makevn-mcp
```

Use `/mcp` in the Codex TUI to confirm that the server is active. Restart or
reload Codex after installing or upgrading makevn.

## Agent Workflow

When using makevn through MCP, agents should follow the same command sequence as
the CLI workflow and should not guess Maven, Docker, or Makefile commands.

Recommended changed-code verification flow:

1. Call `makevn_doctor` first for the target repository.
2. If doctor reports that `.makevn/` is missing, stale, or not initialized, call
   `makevn_init` for that repository.
3. Call `makevn_verify_changes_preview` to surface the affected modules/tests quickly.
4. Call `makevn_verify_changes` to build and test the changed modules/tests.
5. Call `makevn_coverage_changes` only after a coverage-producing run such as
   `makevn_verify_changes`, `makevn_verify_ut_coverage`, or `makevn_verify`.
6. Call `makevn_crap` after a JaCoCo XML report exists when Java CRAP analysis is
   requested. It never downloads the analyzer or produces coverage implicitly.
7. If a command fails, report the failure excerpt or summary as the result; do
   not replace the makevn command with raw `mvn`, raw `docker`, or guessed
   repository-specific scripts.

Tool mapping for common commands:

- `makevn doctor` -> `makevn_doctor`
- `makevn init` -> `makevn_init`
- `makevn profile refresh` -> `makevn_profile_refresh`
- `makevn verify-changes-preview` -> `makevn_verify_changes_preview`
- `makevn verify-changes` -> `makevn_verify_changes`
- `makevn coverage-changes` -> `makevn_coverage_changes`
- `makevn crap` -> `makevn_crap`
- `makevn crap-changes` -> `makevn_crap_changes` (`base` optional; uses existing JaCoCo XML)
- `makevn docker-up` -> `makevn_docker_up`
- `makevn docker-ps-required` -> `makevn_docker_ps_required`

Interpretation rules:

- `makevn_init` is safe to run when doctor indicates the repository needs local
  makevn state. It creates standalone state; `force` refreshes initialization while
  preserving user configuration. Neither mode inspects or removes legacy Make
  artifacts: `.makevn/makevn.mk` and root Makefile includes remain untouched.
  Remove old includes and generated artifacts manually as appropriate; see
  [integration guidance](../docs/integration.md). Uninstall removes `.makevn/`,
  so clean up old Makefile references to it manually as well.
- `makevn_verify_changes` owns Maven module selection. Agents should not add
  their own `-pl`, `-am`, or `-f` flags unless explicitly debugging makevn.
- `makevn_coverage_changes` is a gate. Exit code `1` can be the expected result
  when changed-line, changed-module, or overall coverage is below threshold.
- If a newly installed tool is not visible in the agent schema, restart or reload
  the MCP session. MCP tools are listed when the server starts and may be cached
  by the client.

## Formatting recovery

When a test fails formatter validation, call `makevn_format` with `apply: true`,
then rerun the same test without `fast: true`. For Spotless, pass `file` to
format exactly one existing repository-relative or absolute file:

```json
{"name": "makevn_format", "arguments": {"repo": "/absolute/repo", "apply": true, "file": "module/src/test/java/ExampleTest.java"}}
```

Omit `file` for AMIGA or other unsupported single-file plugins. Do not edit
configuration, add skip flags, or manually imitate formatting to bypass the
failure. Recovery hints are plain text in compact tool output, not structured
JSON fields. Inspect the diff and verify the original test actually passes.
See [the agent recovery workflow](../docs/agents.md#formatting-failure-recovery-for-ai-agents)
and the [makevn skill](../skills/makevn/SKILL.md).

## Development

```bash
./build-rust-dispatcher.sh
./target/release/makevn-mcp
```


### Formatter recovery diagnostics
Test failure output includes the explicit MCP suggestion
`makevn_format` with `apply: true`, as well as `makevn format --apply`.
AMIGA's `File '…' has not been previously formatted` is a formatting
prerequisite failure. The standalone whole-project apply command is supported;
`--file` is not yet supported for AMIGA and must not be suggested for it.

If CLI supports `--file` but MCP does not expose `file`, check the installed
`makevn-mcp` path/version and restart/reload the MCP session after upgrading.
Do not interpret a cached tool schema as evidence that CLI lacks the option.
