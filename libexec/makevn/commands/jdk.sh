#!/usr/bin/env bash
set -euo pipefail

cmd_jdk_current() {
  local repo_root="$1"
  local maven_base_path
  local context java_home

  print_command_intro "${repo_root}" "jdk current"
  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  echo "Global JAVA_HOME: ${JAVA_HOME:-not set}"
  for context in code karate; do
    java_home="$(makevn_effective_java_home "${repo_root}" "${context}" "${maven_base_path}" || true)"
    printf '\nEffective %s JDK: %s\n' "${context}" "${java_home:-unresolved}"
    [[ -z "${java_home}" ]] || makevn_java_version_line "${java_home}"
  done
}

cmd_jdk_list() {
  local jdk_manager
  local repo_root="${1:-$PWD}"
  print_command_intro "${repo_root}" "jdk list"
  jdk_manager="$(makevn_jdk_manager_script)"
  bash "${jdk_manager}" list
}
