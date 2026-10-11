#!/usr/bin/env bash
set -euo pipefail
client="${1:?client required}"
repo="${2:?demo repo required}"
server="${MAKEVN_DEMO_PREFIX:?prepare runtime first}/bin/makevn-mcp"
case "$client" in
  codex)
    mkdir -p "$repo/.codex"
    printf '[mcp_servers.makevn]\ncommand = "%s"\nenabled = true\nstartup_timeout_sec = 20\ntool_timeout_sec = 900\n' "$server" > "$repo/.codex/config.toml"
    ;;
  opencode)
    python3 - "$repo" "$server" <<'PYTHON'
import json, pathlib, sys
pathlib.Path(sys.argv[1], "opencode.json").write_text(json.dumps({"mcp": {"makevn": {
    "type": "local", "command": [sys.argv[2]], "enabled": True, "timeout": 900000}}}))
PYTHON
    ;;
  *) exit 64 ;;
esac
