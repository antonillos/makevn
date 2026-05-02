#!/usr/bin/env bash
set -euo pipefail

makevn_should_drop_verify_prop_flag() {
  local token="$1"

  case "${token}" in
    -DskipTests|-DskipTests=true|-DskipTests=1|-DskipTests=yes|\
    -Dmaven.test.skip|-Dmaven.test.skip=true|-Dmaven.test.skip=1|-Dmaven.test.skip=yes|\
    -DskipIT|-DskipIT=true|-DskipIT=1|-DskipIT=yes|\
    -DskipITs|-DskipITs=true|-DskipITs=1|-DskipITs=yes|\
    -DskipITests|-DskipITests=true|-DskipITests=1|-DskipITests=yes|\
    -DskipIntegrationTests|-DskipIntegrationTests=true|-DskipIntegrationTests=1|-DskipIntegrationTests=yes|\
    -DskipFailsafeTests|-DskipFailsafeTests=true|-DskipFailsafeTests=1|-DskipFailsafeTests=yes|\
    -Dmaven.failsafe.skip|-Dmaven.failsafe.skip=true|-Dmaven.failsafe.skip=1|-Dmaven.failsafe.skip=yes)
      return 0
      ;;
  esac

  return 1
}

makevn_should_drop_maven_cache_prop_flag() {
  local token="$1"

  case "${token}" in
    -Dmaven.build.cache.enabled|-Dmaven.build.cache.enabled=*)
      return 0
      ;;
  esac

  return 1
}

makevn_command_profile_prefix() {
  case "$1" in
    compile) printf '%s\n' COMPILE ;;
    build) printf '%s\n' BUILD ;;
    test) printf '%s\n' TEST ;;
    verify) printf '%s\n' VERIFY ;;
    *) return 1 ;;
  esac
}

makevn_command_profile_path_match() {
  local command_name="$1"
  local workflow_path="$2"
  local workflow_path_lc=""

  workflow_path_lc="$(printf '%s' "${workflow_path}" | tr '[:upper:]' '[:lower:]')"

  case "${command_name}" in
    compile)
      [[ "${workflow_path_lc}" == *compile* ]]
      ;;
    build)
      [[ "${workflow_path_lc}" == *build* || "${workflow_path_lc}" == *package* ]]
      ;;
    test)
      [[ "${workflow_path_lc}" == *test* || "${workflow_path_lc}" == *unit* || "${workflow_path_lc}" == *surefire* ]]
      ;;
    verify)
      [[ "${workflow_path_lc}" == *verify* || "${workflow_path_lc}" == *integration* || "${workflow_path_lc}" == *qa* || "${workflow_path_lc}" == *pr* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

makevn_command_profile_value() {
  local command_name="$1"
  local field_name="$2"
  local prefix=""
  local var_name=""

  prefix="$(makevn_command_profile_prefix "${command_name}")" || return 1
  var_name="MAKEVN_PROFILE_${prefix}_${field_name}"
  printf '%s\n' "${!var_name:-}"
}

makevn_detected_command_profile_value() {
  local command_name="$1"
  local field_name="$2"
  local prefix=""
  local var_name=""

  prefix="$(makevn_command_profile_prefix "${command_name}")" || return 1
  var_name="MAKEVN_DETECTED_${prefix}_${field_name}"
  printf '%s\n' "${!var_name:-}"
}

makevn_detected_command_profile_summary() {
  local command_name="$1"
  local workflow_file=""
  local cli_flags=""
  local prop_flags=""
  local pre_goals=""
  local summary=""

  workflow_file="$(makevn_detected_command_profile_value "${command_name}" WORKFLOW_FILE || true)"
  cli_flags="$(makevn_detected_command_profile_value "${command_name}" CLI_FLAGS || true)"
  prop_flags="$(makevn_detected_command_profile_value "${command_name}" PROP_FLAGS || true)"
  pre_goals="$(makevn_detected_command_profile_value "${command_name}" PRE_GOALS || true)"

  if [[ -z "${workflow_file}" ]]; then
    printf '%s\n' none
    return 0
  fi

  summary="${workflow_file}"
  if [[ -n "${pre_goals}" ]]; then
    summary+=" | pre-goals: ${pre_goals}"
  fi
  if [[ -n "${cli_flags}" ]]; then
    summary+=" | cli: ${cli_flags}"
  fi
  if [[ -n "${prop_flags}" ]]; then
    summary+=" | props: ${prop_flags}"
  fi

  printf '%s\n' "${summary}"
}

makevn_set_detected_command_profile() {
  local command_name="$1"
  local workflow_file="$2"
  local cli_flags="$3"
  local prop_flags="$4"
  local pre_goals="$5"
  local score="$6"
  local prefix=""
  local var_name=""

  prefix="$(makevn_command_profile_prefix "${command_name}")" || return 1
  var_name="MAKEVN_DETECTED_${prefix}_WORKFLOW_FILE"
  printf -v "${var_name}" '%s' "${workflow_file}"
  var_name="MAKEVN_DETECTED_${prefix}_CLI_FLAGS"
  printf -v "${var_name}" '%s' "${cli_flags}"
  var_name="MAKEVN_DETECTED_${prefix}_PROP_FLAGS"
  printf -v "${var_name}" '%s' "${prop_flags}"
  var_name="MAKEVN_DETECTED_${prefix}_PRE_GOALS"
  printf -v "${var_name}" '%s' "${pre_goals}"
  var_name="MAKEVN_DETECTED_${prefix}_SCORE"
  printf -v "${var_name}" '%s' "${score}"
}

makevn_init_detected_command_profiles() {
  makevn_set_detected_command_profile compile "" "" "" "" -1
  makevn_set_detected_command_profile build "" "" "" "" -1
  makevn_set_detected_command_profile test "" "" "" "" -1
  makevn_set_detected_command_profile verify "" "" "" "" -1
}

makevn_extract_maven_invocation() {
  local line="$1"

  case "${line}" in
    *"./mvnw "*)
      printf './mvnw %s\n' "${line#*./mvnw }"
      return 0
      ;;
    *"mvnw "*)
      printf 'mvnw %s\n' "${line#*mvnw }"
      return 0
      ;;
    *"mvn "*)
      printf 'mvn %s\n' "${line#*mvn }"
      return 0
      ;;
  esac

  return 1
}

makevn_detect_command_profile_from_invocation() {
  local workflow_file="$1"
  local invocation="$2"
  local -a tokens=()
  local -a goals=()
  local -a pre_goals=()
  local cli_flags=""
  local prop_flags=""
  local token=""
  local skip_next=false
  local goal=""
  local command_name=""
  local primary_goal_count=0
  local primary_goal_index=-1
  local current_score=0
  local score=0
  local i=0
  local pre_goals_value=""

  read -r -a tokens <<< "${invocation}"
  [[ ${#tokens[@]} -gt 1 ]] || return 0

  for ((i = 1; i < ${#tokens[@]}; i++)); do
    token="${tokens[$i]}"

    if [[ "${skip_next}" == true ]]; then
      skip_next=false
      continue
    fi

    case "${token}" in
      -B|--batch-mode)
        cli_flags="$(makevn_append_word "${cli_flags}" "-B")"
        ;;
      -nsu|--no-snapshot-updates)
        cli_flags="$(makevn_append_word "${cli_flags}" "-nsu")"
        ;;
      -f|--file|-pl|--projects|-rf|--resume-from|-s|--settings|-gs|--global-settings|-t|--toolchains)
        skip_next=true
        ;;
      -D*)
        prop_flags="$(makevn_append_word "${prop_flags}" "${token}")"
        ;;
      -*)
        ;;
      *)
        goals+=("${token}")
        ;;
    esac
  done

  for ((i = 0; i < ${#goals[@]}; i++)); do
    case "${goals[$i]}" in
      compile|package|test|verify)
        goal="${goals[$i]}"
        primary_goal_index=${i}
        primary_goal_count=$((primary_goal_count + 1))
        ;;
    esac
  done

  [[ ${primary_goal_count} -eq 1 ]] || return 0

  if [[ "${goal}" == "package" ]]; then
    command_name="build"
  else
    command_name="${goal}"
  fi

  for ((i = 0; i < primary_goal_index; i++)); do
    if [[ "${command_name}" != "verify" && "${goals[$i]}" == "clean" ]]; then
      pre_goals+=("clean")
    fi
  done

  if [[ "${command_name}" == "build" ]]; then
    local filtered_prop_flags=""
    for token in ${prop_flags}; do
      if [[ "${token}" != "-DskipTests" ]]; then
        filtered_prop_flags="$(makevn_append_word "${filtered_prop_flags}" "${token}")"
      fi
    done
    prop_flags="${filtered_prop_flags}"
  elif [[ "${command_name}" == "verify" ]]; then
    local filtered_prop_flags=""
    for token in ${prop_flags}; do
      if ! makevn_should_drop_verify_prop_flag "${token}"; then
        filtered_prop_flags="$(makevn_append_word "${filtered_prop_flags}" "${token}")"
      fi
    done
    prop_flags="${filtered_prop_flags}"
  fi

  score=10
  if makevn_command_profile_path_match "${command_name}" "${workflow_file}"; then
    score=$((score + 30))
  fi
  if [[ ${#goals[@]} -eq 1 ]]; then
    score=$((score + 10))
  fi
  if [[ ${#goals[@]} -eq 2 && "${goals[0]}" == "clean" ]]; then
    score=$((score + 8))
  fi
  if [[ "${command_name}" == "build" && " ${invocation} " == *" -DskipTests "* ]]; then
    score=$((score + 5))
  fi

  current_score="$(makevn_detected_command_profile_value "${command_name}" SCORE || true)"
  [[ -n "${current_score}" ]] || current_score=-1
  if (( score <= current_score )); then
    return 0
  fi

  if [[ ${#pre_goals[@]} -gt 0 ]]; then
    pre_goals_value="${pre_goals[*]}"
  fi

  makevn_set_detected_command_profile \
    "${command_name}" \
    "${workflow_file}" \
    "${cli_flags}" \
    "${prop_flags}" \
    "${pre_goals_value}" \
    "${score}"
}

makevn_detect_maven_base_path_fresh() {
  local repo_root="$1"
  local first_pom=""

  if [[ -f "${repo_root}/pom.xml" ]]; then
    printf '%s\n' "${repo_root}"
    return 0
  fi

  if [[ -f "${repo_root}/code/pom.xml" ]]; then
    printf '%s\n' "${repo_root}/code"
    return 0
  fi

  first_pom="$(find "${repo_root}" -name pom.xml -not -path '*/target/*' -not -path '*/node_modules/*' 2>/dev/null | LC_ALL=C sort | head -n 1 || true)"
  if [[ -n "${first_pom}" ]]; then
    printf '%s\n' "$(dirname "${first_pom}")"
    return 0
  fi

  return 1
}

makevn_detect_code_tool_versions_fresh() {
  local repo_root="$1"
  local maven_base_path="$2"

  if [[ -n "${maven_base_path}" && -f "${maven_base_path}/.tool-versions" ]]; then
    printf '%s\n' "${maven_base_path}/.tool-versions"
    return 0
  fi

  if [[ -f "${repo_root}/.tool-versions" ]]; then
    printf '%s\n' "${repo_root}/.tool-versions"
    return 0
  fi

  return 1
}

makevn_detect_karate_tool_versions_fresh() {
  local repo_root="$1"

  if [[ -f "${repo_root}/e2e/karate/.tool-versions" ]]; then
    printf '%s\n' "${repo_root}/e2e/karate/.tool-versions"
    return 0
  fi

  return 1
}

makevn_detect_boot_module_name() {
  local repo_root="$1"

  if [[ -d "${repo_root}/code/boot" ]]; then
    printf '%s\n' boot
    return 0
  fi

  if [[ -d "${repo_root}/code/application" ]]; then
    printf '%s\n' application
    return 0
  fi

  if [[ -d "${repo_root}/code/app" ]]; then
    printf '%s\n' app
    return 0
  fi

  printf '%s\n' boot
}

makevn_boot_compose_file_path() {
  local repo_root="$1"
  local boot_module=""

  boot_module="$(makevn_detect_boot_module_name "${repo_root}")"
  printf '%s/code/%s/src/test/resources/compose/docker-compose.yml\n' "${repo_root}" "${boot_module}"
}

makevn_boot_compose_override_file_path() {
  local repo_root="$1"
  local boot_module=""

  boot_module="$(makevn_detect_boot_module_name "${repo_root}")"
  printf '%s/code/%s/src/test/resources/compose/docker-compose.override.yml\n' "${repo_root}" "${boot_module}"
}

makevn_detect_jacoco_module_name() {
  local maven_base_path="$1"

  if [[ -d "${maven_base_path}/jacoco-report-aggregate" ]]; then
    printf '%s\n' jacoco-report-aggregate
    return 0
  fi

  if [[ -d "${maven_base_path}/coverage-report" ]]; then
    printf '%s\n' coverage-report
    return 0
  fi

  if [[ -d "${maven_base_path}/test-coverage" ]]; then
    printf '%s\n' test-coverage
    return 0
  fi

  return 1
}

makevn_jacoco_report_dir() {
  local maven_base_path="$1"
  local jacoco_module=""

  jacoco_module="$(makevn_detect_jacoco_module_name "${maven_base_path}" || true)"
  [[ -n "${jacoco_module}" ]] || return 1
  printf '%s/%s/target/site/jacoco-aggregate\n' "${maven_base_path}" "${jacoco_module}"
}

makevn_print_jacoco_report_hint() {
  local maven_base_path="$1"
  local report_dir=""

  report_dir="$(makevn_jacoco_report_dir "${maven_base_path}" || true)"
  [[ -n "${report_dir}" ]] || return 0
  [[ -f "${report_dir}/index.html" ]] || return 0
  makevn_print_item "coverage report" "${report_dir}/index.html"
}

makevn_internal_make_script_path() {
  local script_name="$1"
  local candidate=""

  candidate="${SCRIPT_DIR}/${script_name}"
  if [[ -f "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  return 1
}

makevn_detect_parent_branch_spec() {
  local repo_root="$1"
  local current_branch=""
  local candidate=""

  current_branch="$(git -C "${repo_root}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  case "${current_branch}" in
    develop|main|HEAD)
      printf '%s\n' HEAD
      return 0
      ;;
  esac

  for candidate in origin/develop develop origin/main main origin/master master; do
    if git -C "${repo_root}" rev-parse --verify "${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}...HEAD"
      return 0
    fi
  done

  printf '%s\n' HEAD
}

makevn_detect_maven_base_path() {
  local repo_root="$1"
  makevn_load_profile "${repo_root}"

  if [[ -n "${MAKEVN_PROFILE_MAVEN_BASE_PATH:-}" && -f "${MAKEVN_PROFILE_MAVEN_BASE_PATH}/pom.xml" ]]; then
    printf '%s\n' "${MAKEVN_PROFILE_MAVEN_BASE_PATH}"
    return 0
  fi

  makevn_detect_maven_base_path_fresh "${repo_root}"
}

makevn_detect_code_tool_versions() {
  local repo_root="$1"
  local maven_base_path="$2"

  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_CODE_TOOL_VERSIONS:-}" ]]; then
    printf '%s\n' "${MAKEVN_CODE_TOOL_VERSIONS}"
    return 0
  fi

  makevn_load_profile "${repo_root}"
  if [[ -n "${MAKEVN_PROFILE_CODE_TOOL_VERSIONS:-}" && -f "${MAKEVN_PROFILE_CODE_TOOL_VERSIONS}" ]]; then
    printf '%s\n' "${MAKEVN_PROFILE_CODE_TOOL_VERSIONS}"
    return 0
  fi

  makevn_detect_code_tool_versions_fresh "${repo_root}" "${maven_base_path}"
}

makevn_detect_karate_tool_versions() {
  local repo_root="$1"

  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_KARATE_TOOL_VERSIONS:-}" ]]; then
    printf '%s\n' "${MAKEVN_KARATE_TOOL_VERSIONS}"
    return 0
  fi

  makevn_load_profile "${repo_root}"
  if [[ -n "${MAKEVN_PROFILE_KARATE_TOOL_VERSIONS:-}" && -f "${MAKEVN_PROFILE_KARATE_TOOL_VERSIONS}" ]]; then
    printf '%s\n' "${MAKEVN_PROFILE_KARATE_TOOL_VERSIONS}"
    return 0
  fi

  makevn_detect_karate_tool_versions_fresh "${repo_root}"
}

makevn_detect_workflow_maven_flags() {
  local repo_root="$1"
  local workflow_root="${repo_root}/.github/workflows"
  local workflow_path=""
  local relative_path=""
  local line=""
  local invocation=""

  MAKEVN_DETECTED_WORKFLOW_FILES=""
  MAKEVN_DETECTED_MAVEN_CLI_FLAGS=""
  MAKEVN_DETECTED_MAVEN_PROP_FLAGS=""
  makevn_init_detected_command_profiles

  [[ -d "${workflow_root}" ]] || return 0

  while IFS= read -r workflow_path; do
    relative_path="${workflow_path#${repo_root}/}"
    MAKEVN_DETECTED_WORKFLOW_FILES="$(makevn_append_word "${MAKEVN_DETECTED_WORKFLOW_FILES}" "${relative_path}")"

    while IFS= read -r line; do
      case "${line}" in
        *"mvn "*|*"./mvnw "*|*"mvnw "*)
          invocation="$(makevn_extract_maven_invocation "${line}" || true)"
          if [[ "${line}" == *" -B"* || "${line}" == *" --batch-mode"* ]]; then
            MAKEVN_DETECTED_MAVEN_CLI_FLAGS="$(makevn_append_word "${MAKEVN_DETECTED_MAVEN_CLI_FLAGS}" "-B")"
          fi

          if [[ "${line}" == *" -nsu"* || "${line}" == *" --no-snapshot-updates"* ]]; then
            MAKEVN_DETECTED_MAVEN_CLI_FLAGS="$(makevn_append_word "${MAKEVN_DETECTED_MAVEN_CLI_FLAGS}" "-nsu")"
          fi

          if [[ -n "${invocation}" ]]; then
            makevn_detect_command_profile_from_invocation "${relative_path}" "${invocation}"
          fi
          ;;
      esac
    done < "${workflow_path}"
  done < <(find "${workflow_root}" -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)
}

makevn_detect_maven_cache_from_repo() {
  local maven_base_path="$1"
  local pom_path=""

  [[ -n "${maven_base_path}" ]] || return 1

  if [[ -f "${maven_base_path}/.mvn/extensions.xml" ]] && grep -Eq 'maven-build-cache-extension|maven-build-cache' "${maven_base_path}/.mvn/extensions.xml"; then
    return 0
  fi

  if [[ -f "${maven_base_path}/.mvn/maven.config" ]] && grep -Eq 'maven\.build\.cache\.enabled=true' "${maven_base_path}/.mvn/maven.config"; then
    return 0
  fi

  while IFS= read -r pom_path; do
    if grep -Eq 'maven-build-cache-extension|maven\.build\.cache\.enabled' "${pom_path}"; then
      return 0
    fi
  done < <(find "${maven_base_path}" -name pom.xml -not -path '*/target/*' -not -path '*/node_modules/*' 2>/dev/null | LC_ALL=C sort)

  return 1
}

makevn_detect_testcontainers_from_repo() {
  local maven_base_path="$1"
  local pom_path=""

  [[ -n "${maven_base_path}" ]] || return 1

  while IFS= read -r pom_path; do
    if grep -Eq '<groupId>org\.testcontainers</groupId>' "${pom_path}"; then
      return 0
    fi
  done < <(find "${maven_base_path}" -name pom.xml -not -path '*/target/*' -not -path '*/node_modules/*' 2>/dev/null | LC_ALL=C sort)

  return 1
}

makevn_detect_repo_profile() {
  local repo_root="$1"
  local maven_base_path=""
  local code_tool_versions=""
  local karate_tool_versions=""
  local maven_prop_flags=""

  maven_base_path="$(makevn_detect_maven_base_path_fresh "${repo_root}" || true)"
  code_tool_versions="$(makevn_detect_code_tool_versions_fresh "${repo_root}" "${maven_base_path}" || true)"
  karate_tool_versions="$(makevn_detect_karate_tool_versions_fresh "${repo_root}" || true)"

  makevn_detect_workflow_maven_flags "${repo_root}"
  maven_prop_flags=""

  if makevn_detect_maven_cache_from_repo "${maven_base_path}"; then
    maven_prop_flags="$(makevn_append_word "${maven_prop_flags}" "-Dmaven.build.cache.enabled=true")"
    MAKEVN_DETECTED_MAVEN_CACHE_SOURCE="pom"
  else
    MAKEVN_DETECTED_MAVEN_CACHE_SOURCE="unresolved"
  fi

  if makevn_detect_testcontainers_from_repo "${maven_base_path}"; then
    MAKEVN_DETECTED_VERIFY_IT_LOCAL_CONTAINERS="TRUE"
  else
    MAKEVN_DETECTED_VERIFY_IT_LOCAL_CONTAINERS=""
  fi

  MAKEVN_DETECTED_MAVEN_BASE_PATH="${maven_base_path}"
  MAKEVN_DETECTED_CODE_TOOL_VERSIONS="${code_tool_versions}"
  MAKEVN_DETECTED_KARATE_TOOL_VERSIONS="${karate_tool_versions}"
  MAKEVN_DETECTED_MAVEN_PROP_FLAGS="${maven_prop_flags}"
}

makevn_write_profile() {
  local repo_root="$1"
  local profile_path

  makevn_detect_repo_profile "${repo_root}"
  profile_path="$(makevn_profile_path "${repo_root}")"

  {
    printf '# makevn detected repository profile\n'
    printf '# Refresh with `makevn doctor` or `makevn init --force`.\n'
    printf 'MAKEVN_PROFILE_GENERATED_AT=%q\n' "$(makevn_now_utc)"
    printf 'MAKEVN_PROFILE_MAVEN_BASE_PATH=%q\n' "${MAKEVN_DETECTED_MAVEN_BASE_PATH}"
    printf 'MAKEVN_PROFILE_CODE_TOOL_VERSIONS=%q\n' "${MAKEVN_DETECTED_CODE_TOOL_VERSIONS}"
    printf 'MAKEVN_PROFILE_KARATE_TOOL_VERSIONS=%q\n' "${MAKEVN_DETECTED_KARATE_TOOL_VERSIONS}"
    printf 'MAKEVN_PROFILE_WORKFLOW_FILES=%q\n' "${MAKEVN_DETECTED_WORKFLOW_FILES}"
    printf 'MAKEVN_PROFILE_MAVEN_CLI_FLAGS=%q\n' "${MAKEVN_DETECTED_MAVEN_CLI_FLAGS}"
    printf 'MAKEVN_PROFILE_MAVEN_PROP_FLAGS=%q\n' "${MAKEVN_DETECTED_MAVEN_PROP_FLAGS}"
    printf 'MAKEVN_PROFILE_MAVEN_CACHE_SOURCE=%q\n' "${MAKEVN_DETECTED_MAVEN_CACHE_SOURCE}"
    printf 'MAKEVN_PROFILE_COMPILE_WORKFLOW_FILE=%q\n' "${MAKEVN_DETECTED_COMPILE_WORKFLOW_FILE:-}"
    printf 'MAKEVN_PROFILE_COMPILE_CLI_FLAGS=%q\n' "${MAKEVN_DETECTED_COMPILE_CLI_FLAGS:-}"
    printf 'MAKEVN_PROFILE_COMPILE_PROP_FLAGS=%q\n' "${MAKEVN_DETECTED_COMPILE_PROP_FLAGS:-}"
    printf 'MAKEVN_PROFILE_COMPILE_PRE_GOALS=%q\n' "${MAKEVN_DETECTED_COMPILE_PRE_GOALS:-}"
    printf 'MAKEVN_PROFILE_BUILD_WORKFLOW_FILE=%q\n' "${MAKEVN_DETECTED_BUILD_WORKFLOW_FILE:-}"
    printf 'MAKEVN_PROFILE_BUILD_CLI_FLAGS=%q\n' "${MAKEVN_DETECTED_BUILD_CLI_FLAGS:-}"
    printf 'MAKEVN_PROFILE_BUILD_PROP_FLAGS=%q\n' "${MAKEVN_DETECTED_BUILD_PROP_FLAGS:-}"
    printf 'MAKEVN_PROFILE_BUILD_PRE_GOALS=%q\n' "${MAKEVN_DETECTED_BUILD_PRE_GOALS:-}"
    printf 'MAKEVN_PROFILE_TEST_WORKFLOW_FILE=%q\n' "${MAKEVN_DETECTED_TEST_WORKFLOW_FILE:-}"
    printf 'MAKEVN_PROFILE_TEST_CLI_FLAGS=%q\n' "${MAKEVN_DETECTED_TEST_CLI_FLAGS:-}"
    printf 'MAKEVN_PROFILE_TEST_PROP_FLAGS=%q\n' "${MAKEVN_DETECTED_TEST_PROP_FLAGS:-}"
    printf 'MAKEVN_PROFILE_TEST_PRE_GOALS=%q\n' "${MAKEVN_DETECTED_TEST_PRE_GOALS:-}"
    printf 'MAKEVN_PROFILE_VERIFY_WORKFLOW_FILE=%q\n' "${MAKEVN_DETECTED_VERIFY_WORKFLOW_FILE:-}"
    printf 'MAKEVN_PROFILE_VERIFY_CLI_FLAGS=%q\n' "${MAKEVN_DETECTED_VERIFY_CLI_FLAGS:-}"
    printf 'MAKEVN_PROFILE_VERIFY_PROP_FLAGS=%q\n' "${MAKEVN_DETECTED_VERIFY_PROP_FLAGS:-}"
    printf 'MAKEVN_PROFILE_VERIFY_PRE_GOALS=%q\n' "${MAKEVN_DETECTED_VERIFY_PRE_GOALS:-}"
    printf 'MAKEVN_PROFILE_VERIFY_IT_LOCAL_CONTAINERS=%q\n' "${MAKEVN_DETECTED_VERIFY_IT_LOCAL_CONTAINERS:-}"
  } > "${profile_path}"
}

makevn_refresh_profile() {
  local repo_root="$1"
  mkdir -p "$(makevn_state_dir "${repo_root}")"
  makevn_write_profile "${repo_root}"
}

