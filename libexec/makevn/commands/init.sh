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
  local managed_makefile=""
  local generated_root_makefile=""

  print_command_intro "${repo_root}" init

  shift
  cmd_init_parse_options "$@"

  existing_manifest="$(makevn_manifest_path "${repo_root}")"
  if [[ -f "${existing_manifest}" && "${force}" != true ]]; then
    printf '%s\n' "$(makevn_warn "makevn is already initialized.")"
    return 0
  fi

  if [[ -f "${existing_manifest}" ]]; then
    managed_makefile="$(makevn_manifest_value "${repo_root}" managed_makefile || true)"
    generated_root_makefile="$(makevn_manifest_value "${repo_root}" generated_root_makefile || true)"
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
  if [[ -n "${managed_makefile}" || -n "${generated_root_makefile}" ]]; then
    makevn_render_make_include "${MAKEVN_BIN_PATH}" > "${state_dir}/makevn.mk"
  else
    rm -f "${state_dir}/makevn.mk"
  fi

  makevn_write_state_json "${repo_root}" "${managed_makefile}" "${generated_root_makefile}"
  makevn_write_manifest "${repo_root}" "${managed_makefile}" "${generated_root_makefile}"

  printf '%s\n' "$(makevn_accent "Initialized makevn.")"
  makevn_print_item "created" ".makevn/config"
  makevn_print_item "created" ".makevn/profile.env"
  makevn_print_item "created" ".makevn/logs/"
  if [[ -n "${managed_makefile}" || -n "${generated_root_makefile}" ]]; then
    makevn_print_item "updated" ".makevn/makevn.mk"
  fi
}

# Updates the caller-local dry_run options.
cmd_make_install_parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        makevn_die "Unknown make install option: $1"
        ;;
    esac
  done
  return 0
}

makevn_print_make_install_preview() {
  local repo_root="$1" make_include_path="$2" managed_makefile="$3" generated_root_makefile="$4"
  makevn_print_header "Dry run"
  makevn_print_item "repo root" "${repo_root}"
  makevn_print_item "would create" "${make_include_path}"
  if [[ -n "${managed_makefile}" ]]; then
    makevn_print_item "would update" "${managed_makefile}"
  fi
  if [[ -n "${generated_root_makefile}" ]]; then
    makevn_print_item "would create" "${generated_root_makefile}"
  fi
  return 0
}

makevn_print_make_install_result() {
  local managed_makefile="$1" generated_root_makefile="$2"
  printf '%s\n' "$(makevn_accent "Installed Make integration.")"
  makevn_print_item "created" ".makevn/makevn.mk"
  if [[ -n "${managed_makefile}" ]]; then
    makevn_print_item "updated" "${managed_makefile}"
  fi
  if [[ -n "${generated_root_makefile}" ]]; then
    makevn_print_item "created" "${generated_root_makefile}"
  fi
  return 0
}

cmd_make_install() {
  local repo_root="$1"
  local dry_run=false
  local make_include_path
  local managed_makefile=""
  local generated_root_makefile=""
  local integration_status=""

  print_command_intro "${repo_root}" "make install"

  shift
  cmd_make_install_parse_options "$@"

  [[ -f "$(makevn_manifest_path "${repo_root}")" ]] || makevn_die "makevn is not initialized in ${repo_root}. Run 'makevn init' first."

  integration_status="$(makevn_make_integration_status "${repo_root}")"
  if [[ "${integration_status}" != "not installed" ]]; then
    printf '%s\n' "$(makevn_warn "Make integration is already installed.")"
    return 0
  fi

  make_include_path="$(makevn_state_dir "${repo_root}")/makevn.mk"

  if [[ -f "${repo_root}/Makefile" || -f "${repo_root}/GNUmakefile" ]]; then
    managed_makefile="$(basename "$(makevn_single_existing_makefile_path "${repo_root}")")"
  else
    generated_root_makefile="Makefile"
  fi

  if [[ "${dry_run}" == true ]]; then
    makevn_print_make_install_preview "${repo_root}" "${make_include_path}" "${managed_makefile}" "${generated_root_makefile}"
    return 0
  fi

  makevn_render_make_include "${MAKEVN_BIN_PATH}" > "${make_include_path}"

  if [[ -n "${managed_makefile}" ]]; then
    makevn_insert_include_block "${repo_root}/${managed_makefile}"
  fi

  if [[ -n "${generated_root_makefile}" ]]; then
    makevn_write_bootstrap_makefile "${repo_root}"
  fi

  makevn_update_manifest_make_integration "${repo_root}" "${managed_makefile}" "${generated_root_makefile}"

  makevn_print_make_install_result "${managed_makefile}" "${generated_root_makefile}"
}

# Updates the caller-local dry_run options.
cmd_make_uninstall_parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        makevn_die "Unknown make uninstall option: $1"
        ;;
    esac
  done
  return 0
}

cmd_make_uninstall_preview() {
  local repo_root="$1" managed_makefile="$2" generated_root_makefile="$3"
  makevn_print_header "Make uninstall dry run"
  [[ -n "${managed_makefile}" ]] && makevn_print_item "would remove include block from" "${managed_makefile}"
  if [[ -n "${generated_root_makefile}" ]]; then
    if makevn_is_managed_bootstrap_makefile "${repo_root}"; then
      makevn_print_item "would remove root file" "${generated_root_makefile}"
    else
      makevn_print_item "would leave modified root file untouched" "${generated_root_makefile}"
    fi
  fi
  [[ -f "${make_include_path}" ]] && makevn_print_item "would remove" ".makevn/makevn.mk"
  return 0
}

cmd_make_uninstall_remove_makefiles() {
  local repo_root="$1" managed_makefile="$2" generated_root_makefile="$3"
  if [[ -n "${managed_makefile}" && -f "${repo_root}/${managed_makefile}" ]]; then
    makevn_remove_include_block "${repo_root}/${managed_makefile}"
  fi

  if [[ -n "${generated_root_makefile}" ]]; then
    if makevn_is_managed_bootstrap_makefile "${repo_root}"; then
      rm -f "${repo_root}/${generated_root_makefile}"
    else
      printf '%s\n' "$(makevn_warn "Warning: ${generated_root_makefile} was modified after make install and was left untouched.")" >&2
    fi
  fi

  return 0
}

cmd_make_uninstall() {
  local repo_root="$1"
  local dry_run=false
  local managed_makefile=""
  local generated_root_makefile=""
  local make_include_path

  print_command_intro "${repo_root}" "make uninstall"

  shift
  cmd_make_uninstall_parse_options "$@"

  [[ -f "$(makevn_manifest_path "${repo_root}")" ]] || makevn_die "makevn is not initialized in ${repo_root}. Run 'makevn init' first."

  managed_makefile="$(makevn_manifest_value "${repo_root}" managed_makefile || true)"
  generated_root_makefile="$(makevn_manifest_value "${repo_root}" generated_root_makefile || true)"
  make_include_path="$(makevn_state_dir "${repo_root}")/makevn.mk"

  if [[ -z "${managed_makefile}" && -z "${generated_root_makefile}" && ! -f "${make_include_path}" ]]; then
    printf '%s\n' "$(makevn_warn "Make integration is not installed.")"
    return 0
  fi

  if [[ "${dry_run}" == true ]]; then
    cmd_make_uninstall_preview "${repo_root}" "${managed_makefile}" "${generated_root_makefile}"
    return 0
  fi

  cmd_make_uninstall_remove_makefiles "${repo_root}" "${managed_makefile}" "${generated_root_makefile}"
  rm -f "${make_include_path}"
  makevn_update_manifest_make_integration "${repo_root}" "" ""

  printf '%s\n' "$(makevn_accent "Removed Make integration.")"
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

cmd_uninstall_preview() {
  local repo_root="$1" managed_makefile="$2" generated_root_makefile="$3"
  makevn_print_header "Uninstall dry run"
  [[ -n "${managed_makefile}" ]] && makevn_print_item "would remove include block from" "${managed_makefile}"
  if [[ -n "${generated_root_makefile}" ]]; then
    if makevn_is_managed_bootstrap_makefile "${repo_root}"; then
      makevn_print_item "would remove root file" "${generated_root_makefile}"
    else
      makevn_print_item "would leave modified root file untouched" "${generated_root_makefile}"
    fi
  fi
  [[ -f "$(makevn_state_dir "${repo_root}")/makevn.mk" ]] && makevn_print_item "would remove" ".makevn/makevn.mk"
  makevn_print_item "would remove" ".makevn/"
  return 0
}

cmd_uninstall_remove_makefiles() {
  local repo_root="$1" managed_makefile="$2" generated_root_makefile="$3"
  if [[ -n "${managed_makefile}" && -f "${repo_root}/${managed_makefile}" ]]; then
    makevn_remove_include_block "${repo_root}/${managed_makefile}"
  fi

  if [[ -n "${generated_root_makefile}" ]]; then
    if makevn_is_managed_bootstrap_makefile "${repo_root}"; then
      rm -f "${repo_root}/${generated_root_makefile}"
    else
      printf '%s\n' "$(makevn_warn "Warning: ${generated_root_makefile} was modified after initialization and was left untouched.")" >&2
    fi
  fi

  return 0
}

cmd_uninstall() {
  local repo_root="$1"
  local dry_run=false
  local manifest_path
  local managed_makefile
  local generated_root_makefile

  print_command_intro "${repo_root}" uninstall

  shift
  cmd_uninstall_parse_options "$@"

  manifest_path="$(makevn_manifest_path "${repo_root}")"
  [[ -f "${manifest_path}" ]] || makevn_die "makevn is not initialized in ${repo_root}"

  managed_makefile="$(makevn_manifest_value "${repo_root}" managed_makefile || true)"
  generated_root_makefile="$(makevn_manifest_value "${repo_root}" generated_root_makefile || true)"

  if [[ "${dry_run}" == true ]]; then
    cmd_uninstall_preview "${repo_root}" "${managed_makefile}" "${generated_root_makefile}"
    return 0
  fi

  cmd_uninstall_remove_makefiles "${repo_root}" "${managed_makefile}" "${generated_root_makefile}"
  rm -rf "$(makevn_state_dir "${repo_root}")"
  printf '%s\n' "$(makevn_accent "makevn removed from ${repo_root}")"
}
