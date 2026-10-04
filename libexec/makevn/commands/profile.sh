#!/usr/bin/env bash
set -euo pipefail

cmd_profile_refresh() {
  local repo_root="$1"
  local profile_path

  print_command_intro "${repo_root}" "profile refresh"

  shift
  [[ $# -eq 0 ]] || makevn_die "Usage: makevn profile refresh"

  [[ -f "$(makevn_manifest_path "${repo_root}")" ]] || makevn_die "makevn is not initialized in ${repo_root}. Run 'makevn init' first."

  makevn_refresh_profile "${repo_root}"
  profile_path="$(makevn_profile_path "${repo_root}")"

  printf '%s\n' "$(makevn_accent "Profile refreshed.")"
  makevn_print_item "profile" ".makevn/profile.env"
  makevn_print_item "cache source" "${MAKEVN_DETECTED_MAVEN_CACHE_SOURCE:-unresolved}"
  makevn_print_item "Detected Karate app profiles" "${MAKEVN_DETECTED_KARATE_APP_PROFILES:-not resolved}"
  makevn_print_item "Karate profiles source" "${MAKEVN_DETECTED_KARATE_APP_PROFILES_SOURCE:-none}"
  makevn_print_item "Karate profiles candidates" "${MAKEVN_DETECTED_KARATE_APP_PROFILES_CANDIDATES:-none}"
  makevn_print_item "workflows" "${MAKEVN_DETECTED_WORKFLOW_FILES:-none}"
  [[ -f "${profile_path}" ]] || makevn_die "Profile refresh failed: ${profile_path} was not created"
}
