#!/usr/bin/env bash
set -euo pipefail

cmd_refresh() {
  local repo_root="$1"
  local dry_run=false
  local manifest_path
  local was_make_installed=false

  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        makevn_die "Unknown refresh option: $1"
        ;;
    esac
  done

  manifest_path="$(makevn_manifest_path "${repo_root}")"

  makevn_print_header "Refresh"

  if [[ -f "${manifest_path}" ]]; then
    local managed_makefile
    local generated_root_makefile
    managed_makefile="$(makevn_manifest_value "${repo_root}" managed_makefile || true)"
    generated_root_makefile="$(makevn_manifest_value "${repo_root}" generated_root_makefile || true)"
    if [[ -n "${managed_makefile}" || -n "${generated_root_makefile}" ]]; then
      was_make_installed=true
    fi

    if [[ "${dry_run}" == true ]]; then
      makevn_print_item "would remove" "current makevn state"
    else
      cmd_uninstall "${repo_root}"
    fi
  fi

  if [[ "${dry_run}" == true ]]; then
    printf '%s\n' "$(makevn_dim "Dry run. Run 'makevn refresh' to apply.")"
    return 0
  fi

  cmd_init "${repo_root}" --force

  if [[ "${was_make_installed}" == true ]]; then
    printf '%s\n' "$(makevn_dim "Make integration was previously installed. Run 'makevn make install' to restore it.")"
  fi

  printf '%s\n' "$(makevn_accent "makevn refreshed.")"
  printf '%s\n' "$(makevn_dim "Run 'makevn doctor' to verify the new state.")"
}
