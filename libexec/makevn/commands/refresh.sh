#!/usr/bin/env bash
set -euo pipefail

cmd_refresh() {
  local repo_root="$1"
  shift
  # Forced initialization preserves user config and retires legacy generated state.
  cmd_init "${repo_root}" --force "$@"
}
