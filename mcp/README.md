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

## Development

```bash
npm ci
npm run bundle  # produces dist/makevn-mcp.js
node dist/makevn-mcp.js
```
