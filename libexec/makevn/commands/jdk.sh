#!/usr/bin/env bash
set -euo pipefail

cmd_jdk_current() {
  local repo_root="$1"
  local maven_base_path
  local code_tool_versions=""
  local karate_tool_versions=""
  local jdk_manager

  print_command_intro "${repo_root}" "jdk current"

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  code_tool_versions="$(makevn_detect_code_tool_versions "${repo_root}" "${maven_base_path}" || true)"
  karate_tool_versions="$(makevn_detect_karate_tool_versions "${repo_root}" || true)"
  jdk_manager="$(makevn_jdk_manager_script)"
  bash "${jdk_manager}" current-contexts "${code_tool_versions}" "${karate_tool_versions}"
}

cmd_jdk_list() {
  local jdk_manager
  local repo_root="${1:-$PWD}"
  print_command_intro "${repo_root}" "jdk list"
  jdk_manager="$(makevn_jdk_manager_script)"
  bash "${jdk_manager}" list
}
