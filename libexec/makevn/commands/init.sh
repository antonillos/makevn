#!/usr/bin/env bash
set -euo pipefail

# Updates the caller-local dry_run and force options.
cmd_init_parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      --force)
        force=true
        shift
        ;;
      *)
        makevn_die "Unknown init option: $1"
        ;;
    esac
  done
  return 0
}

cmd_init() {
  local repo_root="$1"
  local dry_run=false
  local force=false
  local state_dir
  local config_path
  local logs_dir
  local existing_manifest

  print_command_intro "${repo_root}" init

  shift
  cmd_init_parse_options "$@"

  if [[ -z "$(makevn_detect_maven_base_path "${repo_root}" || true)" ]]; then
    printf '%s\n' "$(makevn_warn "No Maven project detected. init only creates local configuration; Maven commands remain unavailable.")" >&2
  fi

  existing_manifest="$(makevn_manifest_path "${repo_root}")"
  if [[ -f "${existing_manifest}" && "${force}" != true ]]; then
    printf '%s\n' "$(makevn_warn "makevn is already initialized.")"
    return 0
  fi

  state_dir="$(makevn_state_dir "${repo_root}")"
  config_path="$(makevn_config_path "${repo_root}")"
  logs_dir="$(makevn_logs_dir "${repo_root}")"

  if [[ "${dry_run}" == true ]]; then
    makevn_print_header "Dry run"
    makevn_print_item "repo root" "${repo_root}"
    makevn_print_item "would create" "${state_dir}"
    makevn_print_item "would create" "${config_path}"
    makevn_print_item "would create" "$(makevn_profile_path "${repo_root}")"
    makevn_print_item "would create" "${logs_dir}"
    return 0
  fi

  mkdir -p "${logs_dir}"
  [[ -f "${config_path}" ]] || makevn_write_config "${repo_root}"
  makevn_refresh_profile "${repo_root}"
  makevn_update_config_generated_contract_clean_dirs "${repo_root}"
  makevn_write_state_json "${repo_root}"
  makevn_write_manifest "${repo_root}"

  printf '%s\n' "$(makevn_accent "Initialized makevn.")"
  makevn_print_item "created" ".makevn/config"
  makevn_print_item "created" ".makevn/profile.env"
  makevn_print_item "created" ".makevn/logs/"
}

# Updates the caller-local dry_run options.
cmd_uninstall_parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        makevn_die "Unknown uninstall option: $1"
        ;;
    esac
  done
  return 0
}

cmd_uninstall() {
  local repo_root="$1"
  local dry_run=false
  local manifest_path

  print_command_intro "${repo_root}" uninstall

  shift
  cmd_uninstall_parse_options "$@"

  manifest_path="$(makevn_manifest_path "${repo_root}")"
  [[ -f "${manifest_path}" ]] || makevn_die "makevn is not initialized in ${repo_root}"

  if [[ "${dry_run}" == true ]]; then
    makevn_print_item "would remove" ".makevn/"
    return 0
  fi

  rm -rf "$(makevn_state_dir "${repo_root}")"
  printf '%s\n' "$(makevn_accent "makevn removed from ${repo_root}")"
}
