# makevn MCP

The MCP server for makevn has two implementations:

1. **Built-in Rust MCP server** — compiled into the `makevn` binary. Requires the Rust dispatcher.
   No extra dependencies.
2. **JS MCP server** — ships with shell-only installations. Requires Node.js.

To force MCP through the shell frontend, invoke `makevn-shell` explicitly:

```json
{
  "mcpServers": {
    "makevn": {
      "command": "makevn-shell",
      "args": ["--mcp"]
    }
  }
}
```

This bypasses the Rust frontend entirely and guarantees the JS MCP server is
used when Node.js is available.

## OpenCode installation

Add this entry to `~/.config/opencode/opencode.jsonc` under the `"mcp"` key:

```jsonc
"makevn": {
  "type": "local",
  "command": ["makevn-shell", "--mcp"],
  "enabled": true,
  "timeout": 900000
}
```

- `enabled: true` keeps the MCP server always active across sessions
- `timeout: 900000` (15 min) should be sufficient for all synchronous tools. The `mutation` tool spawns in background and returns immediately, so it is not affected by the timeout.

The `makevn-shell` binary must be in `PATH`, or use an absolute path:

```jsonc
"command": ["/path/to/makevn-shell", "--mcp"]
```

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
npm ci
npm run bundle  # produces dist/makevn-mcp.js
node dist/makevn-mcp.js
```
