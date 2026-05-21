#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-${PREFIX}/bin}"
SHELL_BIN="${BIN_DIR}/makevn-shell"
RUST_BIN="${BIN_DIR}/makevn-rust"
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
  local mcp_server="${PREFIX}/libexec/makevn/mcp/makevn-mcp.js"

  if [[ ! -f "${mcp_server}" ]]; then
    printf 'Installed MCP server not found: %s\n' "${mcp_server}" >&2
    exit 1
  fi

  if ! grep -Fq "name: \"${tool_name}\"" "${mcp_server}"; then
    printf 'Installed MCP server is missing tool: %s\n' "${tool_name}" >&2
    printf 'Check the bundle step and reinstall before using MCP agents.\n' >&2
    exit 1
  fi
}

info "Checking prerequisites"
require_command git
require_command node
require_command npm
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

info "Building MCP bundle"
run npm ci --prefix "$SCRIPT_DIR/mcp"
run npm run bundle --prefix "$SCRIPT_DIR/mcp"

info "Installing shell frontend"
run bash "$SCRIPT_DIR/install.sh" --shell
run cp "$BIN_DIR/makevn" "$SHELL_BIN"
run chmod +x "$SHELL_BIN"

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
printf '  - %s\n' "$SHELL_BIN"
printf '  - %s\n' "$RUST_BIN"
printf '  - %s\n' "${PREFIX}/libexec/makevn/mcp/makevn-mcp.js"
