#!/usr/bin/env bash
set -euo pipefail
repo="${1:?usage: run-cataloger-mcp-demo.sh <repo-root>}"
client="$(dirname "$0")/mcp_demo.py"
python3 "$client" "$repo" doctor
python3 "$client" "$repo" init
python3 "$client" "$repo/cataloger-cli" composite_run
