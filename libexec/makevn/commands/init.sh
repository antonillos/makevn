#!/usr/bin/env bash
set -euo pipefail

cmd_init() {
  local repo_root="$1"
  local mode="auto"
  local dry_run=false
  local write_make_include=false
  local force=false
  local resolved_mode
  local state_dir
  local config_path
  local logs_dir
  local make_include_path
  local managed_makefile=""
  local generated_root_makefile=""
  local existing_manifest

  print_command_intro "${repo_root}" init

  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        [[ $# -ge 2 ]] || makevn_die "Missing value for --mode"
        mode="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --write-make-include)
        write_make_include=true
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

  case "${mode}" in
    auto)
      resolved_mode="$(makevn_recommended_mode "${repo_root}")"
      if [[ "${resolved_mode}" == "unsupported" ]]; then
        makevn_die "auto mode only works for detected Java Maven repositories. Use an explicit --mode if you still want local scaffolding."
      fi
      ;;
    standalone|make-include|make-bootstrap)
      resolved_mode="${mode}"
      ;;
    *)
      makevn_die "Unsupported mode: ${mode}"
      ;;
  esac

  if [[ "${resolved_mode}" == "make-bootstrap" ]] && [[ -f "${repo_root}/Makefile" || -f "${repo_root}/GNUmakefile" ]]; then
    makevn_die "make-bootstrap is only allowed when the repo has no Makefile or GNUmakefile"
  fi

  if [[ "${resolved_mode}" != "make-include" && "${write_make_include}" == true ]]; then
    makevn_die "--write-make-include only works with --mode make-include"
  fi

  existing_manifest="$(makevn_manifest_path "${repo_root}")"
  if [[ -f "${existing_manifest}" && "${force}" != true ]]; then
    if [[ "$(makevn_manifest_value "${repo_root}" mode || true)" == "${resolved_mode}" && "${write_make_include}" == false ]]; then
      printf '%s\n' "$(makevn_warn "makevn is already initialized in ${resolved_mode} mode.")"
      return 0
    fi
    makevn_die "makevn is already initialized. Run 'makevn uninstall' first or use --force."
  fi

  state_dir="$(makevn_state_dir "${repo_root}")"
  config_path="$(makevn_config_path "${repo_root}")"
  logs_dir="$(makevn_logs_dir "${repo_root}")"
  make_include_path="${state_dir}/makevn.mk"

  if [[ "${dry_run}" == true ]]; then
    makevn_print_header "Dry run"
    makevn_print_item "repo root" "${repo_root}"
    makevn_print_item "mode" "${resolved_mode}"
    makevn_print_item "would create" "${state_dir}"
    makevn_print_item "would create" "${config_path}"
    makevn_print_item "would create" "$(makevn_profile_path "${repo_root}")"
    makevn_print_item "would create" "${logs_dir}"
    if [[ "${resolved_mode}" != "standalone" ]]; then
      makevn_print_item "would create" "${make_include_path}"
    fi
    if [[ "${resolved_mode}" == "make-bootstrap" ]]; then
      makevn_print_item "would create" "${repo_root}/Makefile"
    fi
    if [[ "${write_make_include}" == true ]]; then
      makevn_print_item "would update" "$(makevn_single_existing_makefile_path "${repo_root}")"
    fi
    return 0
  fi

  mkdir -p "${logs_dir}"
  [[ -f "${config_path}" && "${force}" != true ]] || makevn_write_config "${repo_root}"
  makevn_refresh_profile "${repo_root}"

  if [[ "${resolved_mode}" != "standalone" ]]; then
    makevn_render_make_include "${MAKEVN_BIN_PATH}" > "${make_include_path}"
  else
    rm -f "${make_include_path}"
  fi

  if [[ "${resolved_mode}" == "make-bootstrap" ]]; then
    makevn_write_bootstrap_makefile "${repo_root}"
    generated_root_makefile="Makefile"
  fi

  if [[ "${write_make_include}" == true ]]; then
    managed_makefile="$(basename "$(makevn_single_existing_makefile_path "${repo_root}")")"
    makevn_insert_include_block "${repo_root}/${managed_makefile}"
  fi

  makevn_write_state_json "${repo_root}" "${resolved_mode}" "${managed_makefile}" "${generated_root_makefile}"
  makevn_write_manifest "${repo_root}" "${resolved_mode}" "${managed_makefile}" "${generated_root_makefile}"

  printf '%s\n' "$(makevn_accent "Initialized makevn in ${resolved_mode} mode.")"
  makevn_print_item "created" ".makevn/config"
  makevn_print_item "created" ".makevn/profile.env"
  makevn_print_item "created" ".makevn/logs/"
  if [[ "${resolved_mode}" != "standalone" ]]; then
    makevn_print_item "created" ".makevn/makevn.mk"
  fi
  if [[ -n "${managed_makefile}" ]]; then
    makevn_print_item "updated" "${managed_makefile}"
  fi
  if [[ -n "${generated_root_makefile}" ]]; then
    makevn_print_item "created" "${generated_root_makefile}"
  fi
}

cmd_uninstall() {
  local repo_root="$1"
  local dry_run=false
  local manifest_path
  local managed_makefile
  local generated_root_makefile

  print_command_intro "${repo_root}" uninstall

  shift
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

  manifest_path="$(makevn_manifest_path "${repo_root}")"
  [[ -f "${manifest_path}" ]] || makevn_die "makevn is not initialized in ${repo_root}"

  managed_makefile="$(makevn_manifest_value "${repo_root}" managed_makefile || true)"
  generated_root_makefile="$(makevn_manifest_value "${repo_root}" generated_root_makefile || true)"

  if [[ "${dry_run}" == true ]]; then
    makevn_print_header "Uninstall dry run"
    [[ -n "${managed_makefile}" ]] && makevn_print_item "would remove include block from" "${managed_makefile}"
    if [[ -n "${generated_root_makefile}" ]]; then
      if makevn_is_managed_bootstrap_makefile "${repo_root}"; then
        makevn_print_item "would remove root file" "${generated_root_makefile}"
      else
        makevn_print_item "would leave modified root file untouched" "${generated_root_makefile}"
      fi
    fi
    makevn_print_item "would remove" ".makevn/"
    return 0
  fi

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

  rm -rf "$(makevn_state_dir "${repo_root}")"
  printf '%s\n' "$(makevn_accent "makevn removed from ${repo_root}")"
}

