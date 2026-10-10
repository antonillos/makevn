#!/usr/bin/env bash
set -euo pipefail

makevn_print_doctor_java_details() {
  if [[ -n "${MAKEVN_DOCTOR_CODE_JAVA_HOME_RECOMMENDATION}" ]]; then
    makevn_print_item "Code JDK recommendation" "${MAKEVN_DOCTOR_CODE_JAVA_HOME_RECOMMENDATION}"
  fi
  if [[ -n "${MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE}" ]]; then
    makevn_print_detail_line "  ${MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE}"
  fi
  makevn_print_item "Resolved karate JAVA_HOME" "${MAKEVN_DOCTOR_KARATE_JAVA_HOME}"
  if [[ -n "${MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE}" ]]; then
    makevn_print_detail_line "  ${MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE}"
  fi
  return 0
}

makevn_print_doctor_init_recommendation() {
  [[ -n "${MAKEVN_AGENT_OUTPUT:-}" ]] || return 0
  local recommendation="unavailable (see repository support status)"
  case "${MAKEVN_DOCTOR_SUGGESTED_NEXT}" in
    'makevn init') recommendation='makevn_init (force: false)' ;;
    'makevn init --force') recommendation='makevn_init (force: true)' ;;
    *)
      if [[ "${MAKEVN_DOCTOR_CURRENT_STATUS}" == "initialized" ]]; then
        recommendation='none (already up to date)'
      fi
      ;;
  esac
  makevn_print_item "Init recommendation" "${recommendation}"
}

makevn_print_doctor_suggestions() {
  if [[ "${MAKEVN_DOCTOR_INTERACTIVE_REQUIRED:-false}" == true && "${MAKEVN_DOCTOR_REPO_SUPPORT_STATUS}" == supported ]]; then
    makevn_print_item "Analysis status" "completed (diagnosis only; setup is not complete)"
    makevn_print_item "Setup status" "pending"
    makevn_print_item "Interaction blockers" "${MAKEVN_DOCTOR_INTERACTION_BLOCKERS:-answers_unresolved}"
    makevn_print_item "interactive setup required" "Launch CLI makevn doctor in this repository in an interactive terminal/PTY without --compact or --json. Provide a USER-INTERACTIVE terminal, not merely a captured CLI invocation. If that is unavailable, ask the user to run doctor themselves and wait. Do not retry the same captured command or continue Docker/tests while setup is pending. Let the user answer all prompts; MCP doctor cannot ask them."
  fi
  [[ -n "${MAKEVN_DOCTOR_SUGGESTED_NEXT}${MAKEVN_DOCTOR_SUGGESTED_NOTE}${MAKEVN_DOCTOR_SUGGESTED_OPTIONAL}" ]] || return 0
  [[ -n "${MAKEVN_FRONTEND_STATE_METADATA_OUT:-}" ]] || printf '\n'
  makevn_print_header "Suggested next step"
  if [[ -n "${MAKEVN_DOCTOR_SUGGESTED_NEXT}" ]]; then
    makevn_print_item "next" "${MAKEVN_DOCTOR_SUGGESTED_NEXT}"
  fi
  if [[ -n "${MAKEVN_DOCTOR_SUGGESTED_NOTE}" ]]; then
    makevn_print_item "note" "${MAKEVN_DOCTOR_SUGGESTED_NOTE}"
  fi
  if [[ -n "${MAKEVN_DOCTOR_SUGGESTED_OPTIONAL}" ]]; then
    makevn_print_item "optional" "${MAKEVN_DOCTOR_SUGGESTED_OPTIONAL}"
  fi
  return 0
}

print_doctor() {
  local repo_root="$1"
  local reset_config=false
  local reset_backup=""

  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reset-config)
        reset_config=true
        shift
        ;;
      --compact)
        makevn_enable_compact_output
        shift
        ;;
      *)
        makevn_die "Unknown doctor option: $1"
        ;;
    esac
  done

  if [[ "${reset_config}" == true ]]; then
    makevn_doctor_reset_config "${repo_root}"
  fi
  print_command_intro "${repo_root}" doctor
  makevn_collect_doctor_snapshot "${repo_root}"
  if [[ -n "${MAKEVN_MCP_DOCTOR_METADATA_OUT:-}" ]]; then
    makevn_print_doctor_json > "${MAKEVN_MCP_DOCTOR_METADATA_OUT}"
  fi
  makevn_doctor_progress "Reporting repository analysis"
  if [[ "${MAKEVN_DOCTOR_BUILD_STATUS}" != "current" ]]; then
    makevn_print_item "Doctor build" "${MAKEVN_DOCTOR_BUILD_STATUS}: ${MAKEVN_DOCTOR_PREVIOUS_VERSION} -> ${MAKEVN_VERSION}; repository reanalyzed"
  fi
  if [[ -n "${reset_backup}" ]]; then
    makevn_print_item "Configuration backup" "${reset_backup}"
  fi
  makevn_print_item "Test JVM diagnostics" "${MAKEVN_DOCTOR_TEST_PROCESSES}"
  makevn_print_item "Bind mount diagnostics" "${MAKEVN_DOCTOR_BIND_MOUNTS}"
  makevn_print_doctor_init_recommendation

  if [[ "${MAKEVN_COMPACT_OUTPUT:-}" == "1" ]]; then
    makevn_print_item "Current makevn status" "${MAKEVN_DOCTOR_CURRENT_STATUS}"
    makevn_print_item "Repository support status" "${MAKEVN_DOCTOR_REPO_SUPPORT_STATUS}"
    makevn_print_doctor_suggestions
    return 0
  fi

  makevn_print_header "Repository analysis"
  makevn_print_item "Repo root" "${MAKEVN_DOCTOR_REPO_ROOT}"
  makevn_print_item "Java Maven repo" "${MAKEVN_DOCTOR_JAVA_MAVEN_REPO}"
  makevn_print_item "Maven base path" "${MAKEVN_DOCTOR_MAVEN_BASE_PATH}"
  makevn_print_item "Existing .makevn/" "${MAKEVN_DOCTOR_EXISTING_STATE_DIR}"
  makevn_print_item "Current makevn status" "${MAKEVN_DOCTOR_CURRENT_STATUS}"
  makevn_print_item "Code .tool-versions" "${MAKEVN_DOCTOR_CODE_TOOL_VERSIONS}"
  makevn_print_item "Code Java version" "${MAKEVN_DOCTOR_CODE_JAVA_VERSION}"
  makevn_print_item "Application runnable" "${MAKEVN_DOCTOR_APP_RUNNABLE}"
  makevn_print_item "Karate .tool-versions" "${MAKEVN_DOCTOR_KARATE_TOOL_VERSIONS}"
  makevn_print_item "Detected workflow files" "${MAKEVN_DOCTOR_DETECTED_WORKFLOW_FILES}"
  makevn_print_item "Detected Maven CLI flags" "${MAKEVN_DOCTOR_DETECTED_MAVEN_CLI_FLAGS}"
  makevn_print_item "Detected Maven prop flags" "${MAKEVN_DOCTOR_DETECTED_MAVEN_PROP_FLAGS}"
  makevn_print_item "Detected Maven cache" "${MAKEVN_DOCTOR_DETECTED_MAVEN_CACHE_SOURCE}"
  makevn_print_item "Karate application profiles" "${MAKEVN_DOCTOR_KARATE_APP_PROFILES}"
  makevn_print_item "Karate profiles source" "${MAKEVN_DOCTOR_KARATE_APP_PROFILES_SOURCE}"
  makevn_print_item "Karate profiles candidates" "${MAKEVN_DOCTOR_KARATE_APP_PROFILES_CANDIDATES}"
  makevn_print_item "Configure Karate profiles" "MAKEVN_KARATE_APP_PROFILES in .makevn/config (or SPRING_PROFILES_ACTIVE override)"
  makevn_print_item "Detected app health URL" "${MAKEVN_DOCTOR_DETECTED_APP_HEALTH_URL}"
  makevn_print_item "Detected coverage activation" "${MAKEVN_DOCTOR_DETECTED_COVERAGE_ACTIVATION}"
  makevn_print_item "JaCoCo report layout" "${MAKEVN_DOCTOR_JACOCO_REPORT_LAYOUT}"
  makevn_print_item "JaCoCo report dir" "${MAKEVN_DOCTOR_JACOCO_REPORT_DIR}"
  makevn_print_item "JaCoCo XML reports" "${MAKEVN_DOCTOR_JACOCO_XML_COUNT}"
  makevn_print_item "crap4java analyzer" "${MAKEVN_DOCTOR_CRAP_ANALYZER}"
  makevn_print_item "Detected coverage threshold" "${MAKEVN_DOCTOR_DETECTED_COVERAGE_THRESHOLD}"
  makevn_print_item "Detected coverage-changes threshold" "${MAKEVN_DOCTOR_DETECTED_COVERAGE_CHANGES_THRESHOLD}"
  makevn_print_item "Compile profile" "${MAKEVN_DOCTOR_COMPILE_PROFILE}"
  makevn_print_item "Build profile" "${MAKEVN_DOCTOR_BUILD_PROFILE}"
  makevn_print_item "Test profile" "${MAKEVN_DOCTOR_TEST_PROFILE}"
  makevn_print_item "Verify profile" "${MAKEVN_DOCTOR_VERIFY_PROFILE}"
  makevn_print_item "Resolved code Maven" "${MAKEVN_DOCTOR_CODE_MAVEN}"
  makevn_print_item "Resolved Karate Maven" "${MAKEVN_DOCTOR_KARATE_MAVEN}"
  makevn_print_item "Resolved code JAVA_HOME" "${MAKEVN_DOCTOR_CODE_JAVA_HOME}"
  makevn_print_item "Compatible code JAVA_HOMEs" "${MAKEVN_DOCTOR_COMPATIBLE_CODE_JAVA_HOMES}"
  makevn_print_doctor_java_details
  makevn_print_item "Run command configured" "${MAKEVN_DOCTOR_RUN_CONFIGURED}"
  makevn_print_item "Docker compose file" "${MAKEVN_DOCTOR_COMPOSE_FILE}"
  makevn_print_item "Docker e2e compose file" "${MAKEVN_DOCTOR_E2E_COMPOSE_FILE}"
  makevn_print_item "LOCAL_CONTAINERS default" "${MAKEVN_DOCTOR_LOCAL_CONTAINERS}"
  makevn_print_item "Persisted profile" "${MAKEVN_DOCTOR_PROFILE_STATUS}"
  makevn_print_item "Repository support status" "${MAKEVN_DOCTOR_REPO_SUPPORT_STATUS}"
  makevn_print_item "Mutation testing (PIT)" "${MAKEVN_DOCTOR_MUTATION_AVAILABLE}"
  if [[ "${MAKEVN_DOCTOR_MUTATION_AVAILABLE}" == "yes" && -n "${MAKEVN_DOCTOR_MUTATION_GOAL}" ]]; then
    makevn_print_detail_line "  goal: ${MAKEVN_DOCTOR_MUTATION_GOAL}"
  fi

  makevn_print_doctor_suggestions
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
  reset_backup="${backup}"
  makevn_print_item "configuration backup" "${backup}"
  makevn_refresh_profile "${repo_root}"
}

makevn_doctor_reset_config() {
  local repo_root="$1"
  [[ -t 0 && -t 2 && "${MAKEVN_COMPACT_OUTPUT:-}" != 1 ]] || makevn_die "doctor --reset-config requires an interactive terminal/PTY without --compact or --json. Configuration was not changed."
  [[ "$(makevn_repository_support_status "${repo_root}")" == supported ]] || makevn_die "No Maven project detected; configuration was not changed."
  [[ -f "$(makevn_manifest_path "${repo_root}")" ]] || makevn_die "Initialize the repository with makevn init before resetting configuration."
  makevn_reset_repo_config "${repo_root}"
}
