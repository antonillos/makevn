#!/usr/bin/env bash
set -euo pipefail

makevn_read_editable_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  if command -v zsh >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
    if value="$(MAKEVN_READ_PROMPT="${prompt}" zsh -fc '
      value=""
      vared -p "${MAKEVN_READ_PROMPT}" value < /dev/tty > /dev/tty
      print -r -- "${value}"
    ')"; then
      value="$(makevn_trim "${value}")"
      [[ -n "${value}" ]] || value="${default_value}"
      printf '%s\n' "${value}"
      return 0
    fi
  fi

  printf '%s' "${prompt}" >&2
  read -r value </dev/tty
  value="$(makevn_trim "${value}")"
  [[ -n "${value}" ]] || value="${default_value}"
  printf '%s\n' "${value}"
}

makevn_doctor_progress() {
  local message="$1"
  [[ -t 2 ]] || return 0
  [[ -z "${MAKEVN_BACKEND_DETAIL_OUT:-}" ]] || return 0
  printf '%s %s\n' "$(makevn_dim '…')" "${message}" >&2
}

makevn_collect_doctor_snapshot() {
  local repo_root="$1"
  local maven_base_path=""
  local code_tool_versions=""
  local karate_tool_versions=""
  local code_java_version=""
  local app_runnable="no"
  local code_java_home=""
  local compatible_code_java_homes=""
  local karate_java_home=""
  local code_java_version_line=""
  local karate_java_version_line=""
  local run_configured="no"
  local existing_makefile="no"
  local existing_gnumakefile="no"
  local current_status="not initialized"
  local repo_support_status=""
  local make_integration_status="not installed"
  local profile_path=""
  local profile_status="not generated"
  local detected_workflow_files=""
  local detected_maven_cli_flags=""
  local detected_maven_prop_flags=""
  local detected_maven_cache_source="unresolved"
  local detected_app_health_url=""
  local detected_coverage_activation=""
  local detected_coverage_threshold=""
  local detected_coverage_changes_threshold=""
  local detected_jacoco_report_layout=""
  local detected_jacoco_report_dir=""
  local compile_profile=""
  local build_profile=""
  local test_profile=""
  local verify_profile=""
  local compose_file=""
  local e2e_compose_file=""
  local local_containers_preference=""

  makevn_doctor_progress "Inspecting repository layout"
  if [[ -d "$(makevn_state_dir "${repo_root}")" ]]; then
    makevn_doctor_progress "Refreshing persisted profile"
    makevn_refresh_profile "${repo_root}"
  fi

  makevn_doctor_progress "Scanning workflow and Maven signals"
  makevn_detect_repo_profile "${repo_root}"
  detected_workflow_files="${MAKEVN_DETECTED_WORKFLOW_FILES:-}"
  detected_maven_cli_flags="${MAKEVN_DETECTED_MAVEN_CLI_FLAGS:-}"
  detected_maven_prop_flags="${MAKEVN_DETECTED_MAVEN_PROP_FLAGS:-}"
  detected_maven_cache_source="${MAKEVN_DETECTED_MAVEN_CACHE_SOURCE:-unresolved}"
  detected_app_health_url="${MAKEVN_DETECTED_APP_HEALTH_URL:-}"
  detected_coverage_activation="$(makevn_detected_coverage_activation_summary)"
  detected_coverage_threshold="${MAKEVN_DETECTED_COVERAGE_THRESHOLD:-}"
  detected_coverage_changes_threshold="${MAKEVN_DETECTED_COVERAGE_CHANGES_THRESHOLD:-}"
  compile_profile="$(makevn_detected_command_profile_summary compile)"
  build_profile="$(makevn_detected_command_profile_summary build)"
  test_profile="$(makevn_detected_command_profile_summary test)"
  verify_profile="$(makevn_detected_command_profile_summary verify)"
  app_runnable="${MAKEVN_DETECTED_APP_RUNNABLE:-no}"

  # Resolve compose file: config > profile > auto-detect > interactive prompt
  makevn_doctor_progress "Resolving Docker compose files"
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
        # Ensure config exists before persisting
        if [[ ! -f "$(makevn_config_path "${repo_root}")" ]]; then
          mkdir -p "$(makevn_state_dir "${repo_root}")"
          makevn_write_config "${repo_root}"
        fi
        makevn_update_config_compose_file "${repo_root}" "${compose_file}"
        printf '%s\n' "$(makevn_dim "Saved to .makevn/config (MAKEVN_COMPOSE_FILE).")" >&2
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
        if [[ ! -f "$(makevn_config_path "${repo_root}")" ]]; then
          mkdir -p "$(makevn_state_dir "${repo_root}")"
          makevn_write_config "${repo_root}"
        fi
        makevn_update_config_e2e_compose_file "${repo_root}" "${e2e_compose_file}"
        printf '%s\n' "$(makevn_dim "Saved to .makevn/config (MAKEVN_E2E_COMPOSE_FILE).")" >&2
      else
        e2e_compose_file="ambiguous (${#_e2e_found[@]} files found; set MAKEVN_E2E_COMPOSE_FILE in .makevn/config)"
      fi
    fi
  fi

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  code_tool_versions="$(makevn_detect_code_tool_versions "${repo_root}" "${maven_base_path}" || true)"
  karate_tool_versions="$(makevn_detect_karate_tool_versions "${repo_root}" || true)"
  code_java_version="${MAKEVN_DETECTED_CODE_JAVA_VERSION:-}"
  if [[ -z "${code_java_version}" ]]; then
    makevn_load_profile "${repo_root}"
    code_java_version="${MAKEVN_PROFILE_CODE_JAVA_VERSION:-}"
  fi
  if [[ -z "${code_java_version}" ]]; then
    code_java_version="$(makevn_detect_java_version_from_pom "${maven_base_path}" || true)"
  fi
  if [[ "${app_runnable}" != "yes" ]]; then
    makevn_load_profile "${repo_root}"
    app_runnable="${MAKEVN_PROFILE_APP_RUNNABLE:-${app_runnable}}"
  fi
  if [[ "${app_runnable}" != "yes" ]] && makevn_detect_app_runnable "${repo_root}" "${maven_base_path}"; then
    app_runnable="yes"
  fi
  makevn_doctor_progress "Resolving Java homes"
  code_java_home="$(makevn_effective_java_home "${repo_root}" code "${maven_base_path}" || true)"
  if [[ -z "${code_java_home}" && -n "${code_java_version}" ]]; then
    compatible_code_java_homes="$(makevn_compatible_java_homes_csv "${code_java_version}" || true)"
  fi
  karate_java_home="$(makevn_effective_java_home "${repo_root}" karate "${maven_base_path}" || true)"
  repo_support_status="$(makevn_repository_support_status "${repo_root}")"
  if [[ -n "${maven_base_path}" ]]; then
    detected_jacoco_report_layout="$(makevn_jacoco_report_layout "${maven_base_path}" || true)"
    detected_jacoco_report_dir="$(makevn_jacoco_report_dir "${maven_base_path}" || true)"
  fi

  [[ -f "${repo_root}/Makefile" ]] && existing_makefile="${repo_root}/Makefile"
  [[ -f "${repo_root}/GNUmakefile" ]] && existing_gnumakefile="${repo_root}/GNUmakefile"
  if [[ -f "$(makevn_manifest_path "${repo_root}")" ]]; then
    current_status="initialized"
    make_integration_status="$(makevn_make_integration_status "${repo_root}")"
  fi
  profile_path="$(makevn_profile_path "${repo_root}")"
  [[ -f "${profile_path}" ]] && profile_status="${profile_path}"

  makevn_load_config "${repo_root}"
  if [[ -f "$(makevn_config_path "${repo_root}")" && -n "${MAKEVN_DETECTED_VERIFY_IT_LOCAL_CONTAINERS:-}" && -z "${LOCAL_CONTAINERS+x}" && -z "${MAKEVN_LOCAL_CONTAINERS+x}" && -t 0 && -t 2 ]]; then
    printf '\n' >&2
    printf '%s\n' "$(makevn_warn "Use LOCAL_CONTAINERS=TRUE by default for makevn test/verify commands?")" >&2
    printf '  [1] yes, use local containers\n' >&2
    printf '  [2] no, leave LOCAL_CONTAINERS unset unless I export it\n' >&2
    local _local_choice=""
    while true; do
      printf 'Enter number [1-2]: ' >&2
      read -r _local_choice </dev/tty
      case "${_local_choice}" in
        1)
          makevn_update_config_local_containers "${repo_root}" "TRUE"
          MAKEVN_LOCAL_CONTAINERS="TRUE"
          printf '%s\n' "$(makevn_dim "Saved to .makevn/config (MAKEVN_LOCAL_CONTAINERS).")" >&2
          break
          ;;
        2)
          makevn_update_config_local_containers "${repo_root}" ""
          MAKEVN_LOCAL_CONTAINERS=""
          printf '%s\n' "$(makevn_dim "Saved to .makevn/config (MAKEVN_LOCAL_CONTAINERS).")" >&2
          break
          ;;
        *)
          printf '%s\n' "$(makevn_warn "Invalid selection. Try again.")" >&2
          ;;
      esac
    done
  fi
  [[ -n "${MAKEVN_RUN_CMD:-}" ]] && run_configured="yes"

  # Resolve app health URL: config > detected > interactive prompt
  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_APP_HEALTH_URL:-}" ]]; then
    detected_app_health_url="${MAKEVN_APP_HEALTH_URL} (from config)"
  elif [[ -n "${detected_app_health_url}" && -f "$(makevn_config_path "${repo_root}")" && -t 0 && -t 2 ]]; then
    printf '\n' >&2
    printf '%s\n' "$(makevn_warn "Detected app health URL: ${detected_app_health_url}")" >&2
    printf '%s\n' "  Is this correct? If not, enter the correct URL (or press Enter to keep it)." >&2
    local _health_input=""
    _health_input="$(makevn_read_editable_default "Health URL [${detected_app_health_url}]: " "${detected_app_health_url}")"
    detected_app_health_url="${_health_input}"
    makevn_update_config_app_health_url "${repo_root}" "${detected_app_health_url}"
    printf '%s\n' "$(makevn_dim "Saved to .makevn/config (MAKEVN_APP_HEALTH_URL).")" >&2
  fi

  if [[ -n "${MAKEVN_MIN_COVERAGE_THRESHOLD:-}" ]]; then
    detected_coverage_threshold="${MAKEVN_MIN_COVERAGE_THRESHOLD} (from config)"
  elif [[ -n "${detected_coverage_threshold}" ]]; then
    detected_coverage_threshold="${detected_coverage_threshold} (from workflow)"
  elif [[ -n "${maven_base_path}" && -t 0 && -t 2 ]]; then
    if [[ ! -f "$(makevn_config_path "${repo_root}")" ]]; then
      mkdir -p "$(makevn_state_dir "${repo_root}")"
      makevn_write_config "${repo_root}"
    fi
    printf '\n' >&2
    printf '%s\n' "$(makevn_warn "No minimum coverage threshold detected in workflows.")" >&2
    printf '%s\n' "  Enter the repository coverage gate to use for 'makevn coverage'." >&2
    detected_coverage_threshold="$(makevn_read_editable_default "Minimum coverage threshold [90]: " "90")"
    makevn_update_config_min_coverage_threshold "${repo_root}" "${detected_coverage_threshold}"
    printf '%s\n' "$(makevn_dim "Saved to .makevn/config (MAKEVN_MIN_COVERAGE_THRESHOLD).")" >&2
  else
    detected_coverage_threshold="unresolved"
  fi

  if [[ -n "${MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD:-}" ]]; then
    detected_coverage_changes_threshold="${MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD} (from config)"
  elif [[ -n "${detected_coverage_changes_threshold}" ]]; then
    detected_coverage_changes_threshold="${detected_coverage_changes_threshold} (from workflow)"
  elif [[ -n "${maven_base_path}" && -t 0 && -t 2 ]]; then
    if [[ ! -f "$(makevn_config_path "${repo_root}")" ]]; then
      mkdir -p "$(makevn_state_dir "${repo_root}")"
      makevn_write_config "${repo_root}"
    fi
    printf '\n' >&2
    printf '%s\n' "$(makevn_warn "No minimum changed-code coverage threshold detected in workflows.")" >&2
    printf '%s\n' "  Enter the repository coverage gate to use for 'makevn coverage-changes'." >&2
    detected_coverage_changes_threshold="$(makevn_read_editable_default "Changed-code coverage threshold [90]: " "90")"
    makevn_update_config_min_coverage_changes_threshold "${repo_root}" "${detected_coverage_changes_threshold}"
    printf '%s\n' "$(makevn_dim "Saved to .makevn/config (MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD).")" >&2
  else
    detected_coverage_changes_threshold="unresolved"
  fi

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
  MAKEVN_DOCTOR_CURRENT_STATUS="${current_status}"
  MAKEVN_DOCTOR_CODE_TOOL_VERSIONS="${code_tool_versions:-unresolved}"
  MAKEVN_DOCTOR_CODE_JAVA_VERSION="${code_java_version:-unresolved}"
  MAKEVN_DOCTOR_APP_RUNNABLE="${app_runnable:-no}"
  MAKEVN_DOCTOR_KARATE_TOOL_VERSIONS="${karate_tool_versions:-unresolved}"
  MAKEVN_DOCTOR_DETECTED_WORKFLOW_FILES="${detected_workflow_files:-none}"
  MAKEVN_DOCTOR_DETECTED_MAVEN_CLI_FLAGS="${detected_maven_cli_flags:-none}"
  MAKEVN_DOCTOR_DETECTED_MAVEN_PROP_FLAGS="${detected_maven_prop_flags:-none}"
  MAKEVN_DOCTOR_DETECTED_MAVEN_CACHE_SOURCE="${detected_maven_cache_source}"
  MAKEVN_DOCTOR_DETECTED_APP_HEALTH_URL="${detected_app_health_url:-not detected}"
  MAKEVN_DOCTOR_DETECTED_COVERAGE_ACTIVATION="${detected_coverage_activation:-none}"
  MAKEVN_DOCTOR_JACOCO_REPORT_LAYOUT="${detected_jacoco_report_layout:-not detected}"
  MAKEVN_DOCTOR_JACOCO_REPORT_DIR="${detected_jacoco_report_dir:-not detected}"
  MAKEVN_DOCTOR_DETECTED_COVERAGE_THRESHOLD="${detected_coverage_threshold}"
  MAKEVN_DOCTOR_DETECTED_COVERAGE_CHANGES_THRESHOLD="${detected_coverage_changes_threshold}"
  MAKEVN_DOCTOR_COMPILE_PROFILE="${compile_profile}"
  MAKEVN_DOCTOR_BUILD_PROFILE="${build_profile}"
  MAKEVN_DOCTOR_TEST_PROFILE="${test_profile}"
  MAKEVN_DOCTOR_VERIFY_PROFILE="${verify_profile}"
  MAKEVN_DOCTOR_CODE_JAVA_HOME="${code_java_home:-unresolved}"
  MAKEVN_DOCTOR_COMPATIBLE_CODE_JAVA_HOMES="${compatible_code_java_homes:-none}"
  MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE="${code_java_version_line}"
  MAKEVN_DOCTOR_KARATE_JAVA_HOME="${karate_java_home:-unresolved}"
  MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE="${karate_java_version_line}"
  MAKEVN_DOCTOR_RUN_CONFIGURED="${run_configured}"
  MAKEVN_DOCTOR_PROFILE_STATUS="${profile_status}"
  MAKEVN_DOCTOR_REPO_SUPPORT_STATUS="${repo_support_status}"
  MAKEVN_DOCTOR_MAKE_INTEGRATION_STATUS="${make_integration_status}"
  MAKEVN_DOCTOR_COMPOSE_FILE="${compose_file}"
  MAKEVN_DOCTOR_E2E_COMPOSE_FILE="${e2e_compose_file}"
  local_containers_preference="$(makevn_effective_local_containers "${repo_root}" "${MAKEVN_DETECTED_VERIFY_IT_LOCAL_CONTAINERS:-}")"
  MAKEVN_DOCTOR_LOCAL_CONTAINERS="${local_containers_preference:-unset}"
  MAKEVN_DOCTOR_SUGGESTED_NEXT=""
  MAKEVN_DOCTOR_SUGGESTED_OPTIONAL=""
  MAKEVN_DOCTOR_SUGGESTED_NOTE=""

  if [[ "${current_status}" == "not initialized" ]]; then
    case "${repo_support_status}" in
      supported)
        MAKEVN_DOCTOR_SUGGESTED_NEXT="makevn init"
        ;;
      unsupported)
        MAKEVN_DOCTOR_SUGGESTED_NOTE="no automatic recommendation: Maven repository signals were not detected"
        MAKEVN_DOCTOR_SUGGESTED_OPTIONAL="makevn init"
        ;;
    esac
  else
    case "${make_integration_status}" in
      include:*|bootstrap:*)
        MAKEVN_DOCTOR_SUGGESTED_OPTIONAL="makevn make uninstall"
        ;;
    esac
  fi

  case "${repo_support_status}" in
    unsupported)
      MAKEVN_DOCTOR_SUGGESTED_NOTE="no automatic recommendation: Maven repository signals were not detected"
      [[ -n "${MAKEVN_DOCTOR_SUGGESTED_OPTIONAL}" ]] || MAKEVN_DOCTOR_SUGGESTED_OPTIONAL="makevn init"
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
  printf '    "current_makevn_status": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CURRENT_STATUS}")"
  printf '    "code_tool_versions": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CODE_TOOL_VERSIONS}")"
  printf '    "code_java_version": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CODE_JAVA_VERSION}")"
  printf '    "application_runnable": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_APP_RUNNABLE}")"
  printf '    "karate_tool_versions": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_KARATE_TOOL_VERSIONS}")"
  printf '    "detected_workflow_files": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_WORKFLOW_FILES}")"
  printf '    "detected_maven_cli_flags": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_MAVEN_CLI_FLAGS}")"
  printf '    "detected_maven_prop_flags": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_MAVEN_PROP_FLAGS}")"
  printf '    "detected_maven_cache": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_MAVEN_CACHE_SOURCE}")"
  printf '    "detected_app_health_url": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_APP_HEALTH_URL}")"
  printf '    "detected_coverage_activation": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_COVERAGE_ACTIVATION}")"
  printf '    "jacoco_report_layout": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_JACOCO_REPORT_LAYOUT}")"
  printf '    "jacoco_report_dir": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_JACOCO_REPORT_DIR}")"
  printf '    "detected_coverage_threshold": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_COVERAGE_THRESHOLD}")"
  printf '    "detected_coverage_changes_threshold": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_COVERAGE_CHANGES_THRESHOLD}")"
  printf '    "compile_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_COMPILE_PROFILE}")"
  printf '    "build_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_BUILD_PROFILE}")"
  printf '    "test_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_TEST_PROFILE}")"
  printf '    "verify_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_VERIFY_PROFILE}")"
  printf '    "resolved_code_java_home": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CODE_JAVA_HOME}")"
  printf '    "compatible_code_java_homes": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_COMPATIBLE_CODE_JAVA_HOMES}")"
  printf '    "resolved_code_java_version": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE}")"
  printf '    "resolved_karate_java_home": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_KARATE_JAVA_HOME}")"
  printf '    "resolved_karate_java_version": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE}")"
  printf '    "run_command_configured": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_RUN_CONFIGURED}")"
  printf '    "local_containers_default": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_LOCAL_CONTAINERS}")"
  printf '    "persisted_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_PROFILE_STATUS}")"
  printf '    "repository_support_status": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_REPO_SUPPORT_STATUS}")"
  printf '    "make_integration_status": "%s"\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_MAKE_INTEGRATION_STATUS}")"
  printf '  },\n'
  printf '  "suggested_next_step": {\n'
  printf '    "next": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_SUGGESTED_NEXT}")"
  printf '    "optional": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_SUGGESTED_OPTIONAL}")"
  printf '    "note": "%s"\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_SUGGESTED_NOTE}")"
  printf '  }\n'
  printf '}\n'
}
