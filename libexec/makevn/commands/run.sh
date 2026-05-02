#!/usr/bin/env bash
set -euo pipefail

cmd_run() {
  local repo_root="$1"
  local maven_base_path
  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  print_command_intro "${repo_root}" run
  makevn_run_command_configured "${repo_root}" "${maven_base_path}"
}

