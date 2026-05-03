#!/usr/bin/env bash
set -euo pipefail

print_doctor() {
  local repo_root="$1"

  print_command_intro "${repo_root}" doctor
  makevn_collect_doctor_snapshot "${repo_root}"

  makevn_print_header "Repository analysis"
  makevn_print_item "Repo root" "${MAKEVN_DOCTOR_REPO_ROOT}"
  makevn_print_item "Java Maven repo" "${MAKEVN_DOCTOR_JAVA_MAVEN_REPO}"
  makevn_print_item "Maven base path" "${MAKEVN_DOCTOR_MAVEN_BASE_PATH}"
  makevn_print_item "Existing Makefile" "${MAKEVN_DOCTOR_EXISTING_MAKEFILE}"
  makevn_print_item "Existing GNUmakefile" "${MAKEVN_DOCTOR_EXISTING_GNUMAKEFILE}"
  makevn_print_item "Existing .makevn/" "${MAKEVN_DOCTOR_EXISTING_STATE_DIR}"
  makevn_print_item "Current makevn mode" "${MAKEVN_DOCTOR_CURRENT_MODE}"
  makevn_print_item "Code .tool-versions" "${MAKEVN_DOCTOR_CODE_TOOL_VERSIONS}"
  makevn_print_item "Karate .tool-versions" "${MAKEVN_DOCTOR_KARATE_TOOL_VERSIONS}"
  makevn_print_item "Detected workflow files" "${MAKEVN_DOCTOR_DETECTED_WORKFLOW_FILES}"
  makevn_print_item "Detected Maven CLI flags" "${MAKEVN_DOCTOR_DETECTED_MAVEN_CLI_FLAGS}"
  makevn_print_item "Detected Maven prop flags" "${MAKEVN_DOCTOR_DETECTED_MAVEN_PROP_FLAGS}"
  makevn_print_item "Detected Maven cache" "${MAKEVN_DOCTOR_DETECTED_MAVEN_CACHE_SOURCE}"
  makevn_print_item "Compile profile" "${MAKEVN_DOCTOR_COMPILE_PROFILE}"
  makevn_print_item "Build profile" "${MAKEVN_DOCTOR_BUILD_PROFILE}"
  makevn_print_item "Test profile" "${MAKEVN_DOCTOR_TEST_PROFILE}"
  makevn_print_item "Verify profile" "${MAKEVN_DOCTOR_VERIFY_PROFILE}"
  makevn_print_item "Resolved code JAVA_HOME" "${MAKEVN_DOCTOR_CODE_JAVA_HOME}"
  if [[ -n "${MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE}" ]]; then
    printf '  %s\n' "$(makevn_dim "${MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE}")"
  fi
  makevn_print_item "Resolved karate JAVA_HOME" "${MAKEVN_DOCTOR_KARATE_JAVA_HOME}"
  if [[ -n "${MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE}" ]]; then
    printf '  %s\n' "$(makevn_dim "${MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE}")"
  fi
  makevn_print_item "Run command configured" "${MAKEVN_DOCTOR_RUN_CONFIGURED}"
  makevn_print_item "Docker compose file" "${MAKEVN_DOCTOR_COMPOSE_FILE}"
  makevn_print_item "Docker e2e compose file" "${MAKEVN_DOCTOR_E2E_COMPOSE_FILE}"
  makevn_print_item "LOCAL_CONTAINERS default" "${MAKEVN_DOCTOR_LOCAL_CONTAINERS}"
  makevn_print_item "Persisted profile" "${MAKEVN_DOCTOR_PROFILE_STATUS}"
  makevn_print_item "Recommended mode" "${MAKEVN_DOCTOR_RECOMMENDED_MODE}"

  printf '\n'
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
}
