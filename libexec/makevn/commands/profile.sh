#!/usr/bin/env bash
set -euo pipefail

cmd_profile_refresh() {
  local repo_root="$1"
  local profile_path
  local make_include_path

  print_command_intro "${repo_root}" "profile refresh"

  shift
  [[ $# -eq 0 ]] || makevn_die "Usage: makevn profile refresh"

  [[ -f "$(makevn_manifest_path "${repo_root}")" ]] || makevn_die "makevn is not initialized in ${repo_root}. Run 'makevn init' first."

  makevn_refresh_profile "${repo_root}"
  profile_path="$(makevn_profile_path "${repo_root}")"
  make_include_path="$(makevn_state_dir "${repo_root}")/makevn.mk"

  if [[ -f "${make_include_path}" ]]; then
    makevn_render_make_include "${MAKEVN_BIN_PATH}" > "${make_include_path}"
  fi

  printf '%s\n' "$(makevn_accent "Profile refreshed.")"
  makevn_print_item "profile" ".makevn/profile.env"
  if [[ -f "${make_include_path}" ]]; then
    makevn_print_item "updated" ".makevn/makevn.mk"
  fi
  makevn_print_item "cache source" "${MAKEVN_DETECTED_MAVEN_CACHE_SOURCE:-unresolved}"
  makevn_print_item "workflows" "${MAKEVN_DETECTED_WORKFLOW_FILES:-none}"
  [[ -f "${profile_path}" ]] || makevn_die "Profile refresh failed: ${profile_path} was not created"
}
