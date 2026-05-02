#!/usr/bin/env bash
set -euo pipefail

makevn_collect_doctor_snapshot() {
  local repo_root="$1"
  local maven_base_path=""
  local code_tool_versions=""
  local karate_tool_versions=""
  local code_java_home=""
  local karate_java_home=""
  local code_java_version_line=""
  local karate_java_version_line=""
  local run_configured="no"
  local existing_makefile="no"
  local existing_gnumakefile="no"
  local current_mode="not initialized"
  local recommended_mode=""
  local profile_path=""
  local profile_status="not generated"
  local detected_workflow_files=""
  local detected_maven_cli_flags=""
  local detected_maven_prop_flags=""
  local detected_maven_cache_source="unresolved"
  local compile_profile=""
  local build_profile=""
  local test_profile=""
  local verify_profile=""
  local compose_file=""
  local e2e_compose_file=""

  if [[ -d "$(makevn_state_dir "${repo_root}")" ]]; then
    makevn_refresh_profile "${repo_root}"
  fi

  makevn_detect_repo_profile "${repo_root}"
  detected_workflow_files="${MAKEVN_DETECTED_WORKFLOW_FILES:-}"
  detected_maven_cli_flags="${MAKEVN_DETECTED_MAVEN_CLI_FLAGS:-}"
  detected_maven_prop_flags="${MAKEVN_DETECTED_MAVEN_PROP_FLAGS:-}"
  detected_maven_cache_source="${MAKEVN_DETECTED_MAVEN_CACHE_SOURCE:-unresolved}"
  compile_profile="$(makevn_detected_command_profile_summary compile)"
  build_profile="$(makevn_detected_command_profile_summary build)"
  test_profile="$(makevn_detected_command_profile_summary test)"
  verify_profile="$(makevn_detected_command_profile_summary verify)"

  # Resolve compose file: config > profile > auto-detect > interactive prompt
  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_COMPOSE_FILE:-}" && -f "${MAKEVN_COMPOSE_FILE}" ]]; then
    compose_file="${MAKEVN_COMPOSE_FILE}"
  elif [[ -n "${MAKEVN_DETECTED_COMPOSE_FILE:-}" ]]; then
    compose_file="${MAKEVN_DETECTED_COMPOSE_FILE}"
  else
    # Multiple or zero compose files found - try to enumerate and ask
    local -a _found=()
    local _f
    while IFS= read -r _f; do
      [[ -n "${_f}" ]] && _found+=("${_f}")
    done < <(makevn_find_compose_files "${repo_root}")

    if [[ ${#_found[@]} -eq 0 ]]; then
      compose_file="not found"
    elif [[ ${#_found[@]} -eq 1 ]]; then
      compose_file="${_found[0]}"
    else
      # Multiple: ask interactively if we have a TTY
      if [[ -t 0 && -t 2 ]]; then
        printf '\n' >&2
        printf '%s\n' "$(makevn_warn "Multiple docker-compose.yml files found. Select one:")" >&2
        local _i=1
        for _f in "${_found[@]}"; do
          printf '  [%d] %s\n' "${_i}" "${_f}" >&2
          _i=$((_i + 1))
        done
        local _choice=""
        while true; do
          printf 'Enter number [1-%d]: ' "${#_found[@]}" >&2
          read -r _choice </dev/tty
          if [[ "${_choice}" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= ${#_found[@]} )); then
            break
          fi
          printf '%s\n' "$(makevn_warn "Invalid selection. Try again.")" >&2
        done
        compose_file="${_found[$((_choice - 1))]}"
        # Persist in config if config exists
        if [[ -f "$(makevn_config_path "${repo_root}")" ]]; then
          makevn_update_config_compose_file "${repo_root}" "${compose_file}"
          printf '%s\n' "$(makevn_dim "Saved to .makevn/config (MAKEVN_COMPOSE_FILE).")" >&2
        fi
      else
        compose_file="ambiguous (${#_found[@]} files found; set MAKEVN_COMPOSE_FILE in .makevn/config)"
      fi
    fi
  fi

  # Resolve e2e compose file: config > profile > auto-detect > interactive prompt
  if [[ -n "${MAKEVN_E2E_COMPOSE_FILE:-}" && -f "${MAKEVN_E2E_COMPOSE_FILE}" ]]; then
    e2e_compose_file="${MAKEVN_E2E_COMPOSE_FILE}"
  elif [[ -n "${MAKEVN_DETECTED_E2E_COMPOSE_FILE:-}" ]]; then
    e2e_compose_file="${MAKEVN_DETECTED_E2E_COMPOSE_FILE}"
  else
    local -a _e2e_found=()
    local _ef
    while IFS= read -r _ef; do
      [[ -n "${_ef}" ]] && _e2e_found+=("${_ef}")
    done < <(makevn_find_e2e_compose_files "${repo_root}")

    if [[ ${#_e2e_found[@]} -eq 0 ]]; then
      e2e_compose_file="not found"
    elif [[ ${#_e2e_found[@]} -eq 1 ]]; then
      e2e_compose_file="${_e2e_found[0]}"
    else
      if [[ -t 0 && -t 2 ]]; then
        printf '\n' >&2
        printf '%s\n' "$(makevn_warn "Multiple e2e docker-compose.yml files found. Select one:")" >&2
        local _i=1
        for _ef in "${_e2e_found[@]}"; do
          printf '  [%d] %s\n' "${_i}" "${_ef}" >&2
          _i=$((_i + 1))
        done
        local _echoice=""
        while true; do
          printf 'Enter number [1-%d]: ' "${#_e2e_found[@]}" >&2
          read -r _echoice </dev/tty
          if [[ "${_echoice}" =~ ^[0-9]+$ ]] && (( _echoice >= 1 && _echoice <= ${#_e2e_found[@]} )); then
            break
          fi
          printf '%s\n' "$(makevn_warn "Invalid selection. Try again.")" >&2
        done
        e2e_compose_file="${_e2e_found[$((_echoice - 1))]}"
        if [[ -f "$(makevn_config_path "${repo_root}")" ]]; then
          makevn_update_config_e2e_compose_file "${repo_root}" "${e2e_compose_file}"
          printf '%s\n' "$(makevn_dim "Saved to .makevn/config (MAKEVN_E2E_COMPOSE_FILE).")" >&2
        fi
      else
        e2e_compose_file="ambiguous (${#_e2e_found[@]} files found; set MAKEVN_E2E_COMPOSE_FILE in .makevn/config)"
      fi
    fi
  fi

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  code_tool_versions="$(makevn_detect_code_tool_versions "${repo_root}" "${maven_base_path}" || true)"
  karate_tool_versions="$(makevn_detect_karate_tool_versions "${repo_root}" || true)"
  code_java_home="$(makevn_effective_java_home "${repo_root}" code "${maven_base_path}" || true)"
  karate_java_home="$(makevn_effective_java_home "${repo_root}" karate "${maven_base_path}" || true)"
  recommended_mode="$(makevn_recommended_mode "${repo_root}")"

  [[ -f "${repo_root}/Makefile" ]] && existing_makefile="${repo_root}/Makefile"
  [[ -f "${repo_root}/GNUmakefile" ]] && existing_gnumakefile="${repo_root}/GNUmakefile"
  [[ -f "$(makevn_manifest_path "${repo_root}")" ]] && current_mode="$(makevn_manifest_value "${repo_root}" mode || true)"
  profile_path="$(makevn_profile_path "${repo_root}")"
  [[ -f "${profile_path}" ]] && profile_status="${profile_path}"

  makevn_load_config "${repo_root}"
  [[ -n "${MAKEVN_RUN_CMD:-}" ]] && run_configured="yes"

  if [[ -n "${code_java_home}" ]]; then
    code_java_version_line="$(makevn_java_version_line "${code_java_home}")"
  fi

  if [[ -n "${karate_java_home}" ]]; then
    karate_java_version_line="$(makevn_java_version_line "${karate_java_home}")"
  fi

  MAKEVN_DOCTOR_REPO_ROOT="${repo_root}"
  MAKEVN_DOCTOR_JAVA_MAVEN_REPO="$(if [[ -n "${maven_base_path}" ]]; then printf yes; else printf no; fi)"
  MAKEVN_DOCTOR_MAVEN_BASE_PATH="${maven_base_path:-unresolved}"
  MAKEVN_DOCTOR_EXISTING_MAKEFILE="${existing_makefile}"
  MAKEVN_DOCTOR_EXISTING_GNUMAKEFILE="${existing_gnumakefile}"
  MAKEVN_DOCTOR_EXISTING_STATE_DIR="$(if [[ -d "$(makevn_state_dir "${repo_root}")" ]]; then printf yes; else printf no; fi)"
  MAKEVN_DOCTOR_CURRENT_MODE="${current_mode}"
  MAKEVN_DOCTOR_CODE_TOOL_VERSIONS="${code_tool_versions:-unresolved}"
  MAKEVN_DOCTOR_KARATE_TOOL_VERSIONS="${karate_tool_versions:-unresolved}"
  MAKEVN_DOCTOR_DETECTED_WORKFLOW_FILES="${detected_workflow_files:-none}"
  MAKEVN_DOCTOR_DETECTED_MAVEN_CLI_FLAGS="${detected_maven_cli_flags:-none}"
  MAKEVN_DOCTOR_DETECTED_MAVEN_PROP_FLAGS="${detected_maven_prop_flags:-none}"
  MAKEVN_DOCTOR_DETECTED_MAVEN_CACHE_SOURCE="${detected_maven_cache_source}"
  MAKEVN_DOCTOR_COMPILE_PROFILE="${compile_profile}"
  MAKEVN_DOCTOR_BUILD_PROFILE="${build_profile}"
  MAKEVN_DOCTOR_TEST_PROFILE="${test_profile}"
  MAKEVN_DOCTOR_VERIFY_PROFILE="${verify_profile}"
  MAKEVN_DOCTOR_CODE_JAVA_HOME="${code_java_home:-unresolved}"
  MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE="${code_java_version_line}"
  MAKEVN_DOCTOR_KARATE_JAVA_HOME="${karate_java_home:-unresolved}"
  MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE="${karate_java_version_line}"
  MAKEVN_DOCTOR_RUN_CONFIGURED="${run_configured}"
  MAKEVN_DOCTOR_PROFILE_STATUS="${profile_status}"
  MAKEVN_DOCTOR_RECOMMENDED_MODE="${recommended_mode}"
  MAKEVN_DOCTOR_COMPOSE_FILE="${compose_file}"
  MAKEVN_DOCTOR_E2E_COMPOSE_FILE="${e2e_compose_file}"
  MAKEVN_DOCTOR_SUGGESTED_NEXT=""
  MAKEVN_DOCTOR_SUGGESTED_OPTIONAL=""
  MAKEVN_DOCTOR_SUGGESTED_NOTE=""

  case "${recommended_mode}" in
    make-include)
      MAKEVN_DOCTOR_SUGGESTED_NEXT="makevn init --mode make-include"
      MAKEVN_DOCTOR_SUGGESTED_OPTIONAL="makevn init --mode make-include --write-make-include"
      ;;
    standalone)
      MAKEVN_DOCTOR_SUGGESTED_NEXT="makevn init --mode standalone"
      MAKEVN_DOCTOR_SUGGESTED_OPTIONAL="makevn init --mode make-bootstrap"
      ;;
    make-bootstrap)
      MAKEVN_DOCTOR_SUGGESTED_NEXT="makevn init --mode make-bootstrap"
      ;;
    unsupported)
      MAKEVN_DOCTOR_SUGGESTED_NOTE="no automatic recommendation: Maven repository signals were not detected"
      MAKEVN_DOCTOR_SUGGESTED_OPTIONAL="use an explicit mode with makevn init --mode ..."
      ;;
    *)
      MAKEVN_DOCTOR_SUGGESTED_NEXT="makevn uninstall"
      ;;
  esac
}

makevn_print_doctor_json() {
  printf '{\n'
  printf '  "version": 1,\n'
  printf '  "command": "doctor",\n'
  printf '  "repository_analysis": {\n'
  printf '    "repo_root": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_REPO_ROOT}")"
  printf '    "java_maven_repo": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_JAVA_MAVEN_REPO}")"
  printf '    "maven_base_path": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_MAVEN_BASE_PATH}")"
  printf '    "existing_makefile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_EXISTING_MAKEFILE}")"
  printf '    "existing_gnumakefile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_EXISTING_GNUMAKEFILE}")"
  printf '    "existing_makevn": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_EXISTING_STATE_DIR}")"
  printf '    "current_makevn_mode": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CURRENT_MODE}")"
  printf '    "code_tool_versions": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CODE_TOOL_VERSIONS}")"
  printf '    "karate_tool_versions": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_KARATE_TOOL_VERSIONS}")"
  printf '    "detected_workflow_files": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_WORKFLOW_FILES}")"
  printf '    "detected_maven_cli_flags": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_MAVEN_CLI_FLAGS}")"
  printf '    "detected_maven_prop_flags": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_MAVEN_PROP_FLAGS}")"
  printf '    "detected_maven_cache": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_MAVEN_CACHE_SOURCE}")"
  printf '    "compile_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_COMPILE_PROFILE}")"
  printf '    "build_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_BUILD_PROFILE}")"
  printf '    "test_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_TEST_PROFILE}")"
  printf '    "verify_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_VERIFY_PROFILE}")"
  printf '    "resolved_code_java_home": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CODE_JAVA_HOME}")"
  printf '    "resolved_code_java_version": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE}")"
  printf '    "resolved_karate_java_home": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_KARATE_JAVA_HOME}")"
  printf '    "resolved_karate_java_version": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE}")"
  printf '    "run_command_configured": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_RUN_CONFIGURED}")"
  printf '    "persisted_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_PROFILE_STATUS}")"
  printf '    "recommended_mode": "%s"\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_RECOMMENDED_MODE}")"
  printf '  },\n'
  printf '  "suggested_next_step": {\n'
  printf '    "next": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_SUGGESTED_NEXT}")"
  printf '    "optional": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_SUGGESTED_OPTIONAL}")"
  printf '    "note": "%s"\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_SUGGESTED_NOTE}")"
  printf '  }\n'
  printf '}\n'
}

