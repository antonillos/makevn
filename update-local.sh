#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-${PREFIX}/bin}"
RUST_BIN="${BIN_DIR}/makevn-rust"
MCP_BIN="${BIN_DIR}/makevn-mcp"
DO_PULL=1

if [[ "${1:-}" == "--no-pull" ]]; then
  DO_PULL=0
  shift
fi

if [[ $# -gt 0 ]]; then
  printf 'Usage: %s [--no-pull]\n' "$0" >&2
  exit 1
fi

info() {
  printf '\n==> %s\n' "$1"
}

run() {
  printf '  $ %s\n' "$*"
  "$@"
}

missing=()

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    missing+=("$1")
  fi
}

require_installed_mcp_tool() {
  local tool_name="$1"
  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/makevn-mcp-tools.XXXXXX")"

  if [[ ! -x "${MCP_BIN}" ]]; then
    printf 'Installed MCP server not found or not executable: %s\n' "${MCP_BIN}" >&2
    exit 1
  fi

  printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"makevn-update-local","version":"0"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | "${MCP_BIN}" > "${output_file}"

  if ! grep -Fq "\"name\":\"${tool_name}\"" "${output_file}"; then
    printf 'Installed MCP server is missing tool: %s\n' "${tool_name}" >&2
    rm -f "${output_file}"
    exit 1
  fi
  rm -f "${output_file}"
}

info "Checking prerequisites"
require_command git
require_command cargo

if [[ "${#missing[@]}" -gt 0 ]]; then
  printf 'Missing prerequisites:\n' >&2
  for name in "${missing[@]}"; do
    printf '  - %s\n' "$name" >&2
  done
  printf '\nNothing was installed. Install the missing prerequisites and re-run.\n' >&2
  exit 1
fi

if [[ "$DO_PULL" -eq 1 ]]; then
  info "Updating local makevn repo"
  run git -C "$SCRIPT_DIR" pull --ff-only
fi

info "Building Rust frontend"
run bash "$SCRIPT_DIR/build-rust-dispatcher.sh"

info "Installing Rust frontend"
run bash "$SCRIPT_DIR/install.sh" --rust
run cp "$BIN_DIR/makevn" "$RUST_BIN"
run chmod +x "$RUST_BIN"

info "Validating installed MCP tools"
require_installed_mcp_tool docker_up
require_installed_mcp_tool docker_ps_required

printf '\nInstalled artifacts:\n'
printf '  - %s (default frontend: rust)\n' "${BIN_DIR}/makevn"
printf '  - %s\n' "$RUST_BIN"
printf '  - %s\n' "$MCP_BIN"
