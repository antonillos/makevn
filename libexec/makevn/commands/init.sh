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
      --reset-config)
        reset_config=true
        force=true
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
  local reset_config=false
  local state_dir
  local config_path
  local logs_dir
  local existing_manifest

  print_command_intro "${repo_root}" init

  shift
  cmd_init_parse_options "$@"

  if [[ -z "$(makevn_detect_maven_base_path "${repo_root}" || true)" ]]; then
    makevn_die "Cannot initialize makevn: no Maven project detected. No local configuration was created or updated."
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
    [[ "${reset_config}" != true ]] || makevn_print_item "would reset" "config and profile (with backup; installation and logs preserved)"
    makevn_print_item "repo root" "${repo_root}"
    makevn_print_item "would create" "${state_dir}"
    makevn_print_item "would create" "${config_path}"
    makevn_print_item "would create" "$(makevn_profile_path "${repo_root}")"
    makevn_print_item "would create" "${logs_dir}"
    return 0
  fi

  mkdir -p "${logs_dir}"
  if [[ "${reset_config}" == true ]]; then
    makevn_reset_repo_config "${repo_root}"
  fi
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

# Keep installation, logs, and runtime state; back up user settings before reset.
makevn_reset_repo_config() {
  local repo_root="$1"
  local state_dir backup file
  state_dir="$(makevn_state_dir "${repo_root}")"
  backup="$(mktemp -d "${state_dir}/config-backup.XXXXXX")"
  for file in config profile.env; do
    [[ ! -e "${state_dir}/${file}" ]] || cp -p "${state_dir}/${file}" "${backup}/${file}"
  done
  rm -f "${state_dir}/config" "${state_dir}/profile.env"
  makevn_write_config "${repo_root}"
  makevn_print_item "configuration backup" "${backup}"
  makevn_print_item "next" "Run makevn doctor in an interactive terminal without --compact to answer setup questions."
}
