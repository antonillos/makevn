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
3. Call `makevn_verify_changes` to build and test the changed modules/tests.
4. Call `makevn_coverage_changes` only after a coverage-producing run such as
   `makevn_verify_changes`, `makevn_verify_ut_coverage`, or `makevn_verify`.
5. If a command fails, report the failure excerpt or summary as the result; do
   not replace the makevn command with raw `mvn`, raw `docker`, or guessed
   repository-specific scripts.

Tool mapping for common commands:

- `makevn doctor` -> `makevn_doctor`
- `makevn init` -> `makevn_init`
- `makevn profile refresh` -> `makevn_profile_refresh`
- `makevn verify-changes` -> `makevn_verify_changes`
- `makevn coverage-changes` -> `makevn_coverage_changes`
- `makevn docker-up` -> `makevn_docker_up`
- `makevn docker-ps-required` -> `makevn_docker_ps_required`

Interpretation rules:

- `makevn_init` is safe to run when doctor indicates the repository needs local
  makevn state. It does not install root Makefile integration; that is a separate
  `makevn_make_install` operation.
- `makevn_verify_changes` owns Maven module selection. Agents should not add
  their own `-pl`, `-am`, or `-f` flags unless explicitly debugging makevn.
- `makevn_coverage_changes` is a gate. Exit code `1` can be the expected result
  when changed-line, changed-module, or overall coverage is below threshold.
- If a newly installed tool is not visible in the agent schema, restart or reload
  the MCP session. MCP tools are listed when the server starts and may be cached
  by the client.

## Development

```bash
./build-rust-dispatcher.sh
./target/release/makevn-mcp
```
