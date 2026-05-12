# makevn MCP

The MCP server for makevn has two implementations:

1. **Built-in Rust MCP server** — compiled into the `makevn` binary. Requires the Rust dispatcher.
   No extra dependencies.
2. **JS MCP server** — ships with shell-only installations. Requires Node.js.

Both are invoked the same way:

```json
{
  "mcpServers": {
    "makevn": {
      "command": "makevn",
      "args": ["--mcp"]
    }
  }
}
```

The shell entrypoint auto-detects the JS bundle and delegates to it when
Node.js is available. The Rust binary handles `--mcp` natively.

## Development

```bash
npm ci
npm run bundle  # produces dist/makevn-mcp.js
node dist/makevn-mcp.js
```
