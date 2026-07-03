#!/usr/bin/env bash
set -euo pipefail

makevn_jdk_manager_script() {
  if [[ -f "${MAKEVN_LIBEXEC_DIR}/jdk/manager.sh" ]]; then
    printf '%s\n' "${MAKEVN_LIBEXEC_DIR}/jdk/manager.sh"
    return 0
  fi

  makevn_die "JDK manager script not found"
}

makevn_resolve_tool_versions_home() {
  local tool_versions_file="$1"
  local jdk_manager
  jdk_manager="$(makevn_jdk_manager_script)"
  bash "${jdk_manager}" resolve-tool-versions "${tool_versions_file}" 2>/dev/null
}

makevn_tool_versions_java_major() {
  local tool_versions_file="$1"
  local configured_jdk=""
  local major=""

  [[ -f "${tool_versions_file}" ]] || return 1
  configured_jdk="$(awk '$1 == "ivm-java" { print $2; exit }' "${tool_versions_file}")"
  [[ -n "${configured_jdk}" ]] || return 1
  major="$(printf '%s\n' "${configured_jdk}" | sed -E 's/.*-([0-9]+)(\..*)?$/\1/')"
  [[ "${major}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${major}"
}

makevn_resolve_java_version_home() {
  local java_version="$1"
  local jdk_manager
  jdk_manager="$(makevn_jdk_manager_script)"
  bash "${jdk_manager}" resolve-version "${java_version}" 2>/dev/null
}

makevn_resolve_compatible_java_version_home() {
  local java_version="$1"
  local jdk_manager
  jdk_manager="$(makevn_jdk_manager_script)"
  bash "${jdk_manager}" resolve-compatible-version "${java_version}" 2>/dev/null
}

makevn_list_compatible_java_homes() {
  local java_version="$1"
  local jdk_manager
  jdk_manager="$(makevn_jdk_manager_script)"
  bash "${jdk_manager}" list-compatible-homes "${java_version}" 2>/dev/null
}

makevn_compatible_java_homes_csv() {
  local java_version="$1"
  local homes=""
  local candidate_home=""

  while IFS= read -r candidate_home; do
    [[ -n "${candidate_home}" ]] || continue
    if [[ -n "${homes}" ]]; then
      homes+=", "
    fi
    homes+="${candidate_home}"
  done < <(makevn_list_compatible_java_homes "${java_version}")

  printf '%s\n' "${homes}"
}

makevn_compatible_java_resolution_hint() {
  local java_version="$1"
  local homes=""
  homes="$(makevn_compatible_java_homes_csv "${java_version}")"
  [[ -n "${homes}" ]] || return 1
  printf 'No exact JDK %s detected. Compatible newer local JDKs: %s. Configure MAKEVN_CODE_JAVA_HOME in .makevn/config after confirming with the user.\n' "${java_version}" "${homes}"
}

makevn_effective_java_home() {
  local repo_root="$1"
  local context="$2"
  local maven_base_path="$3"
  local tool_versions_file=""

  makevn_load_config "${repo_root}"

  if [[ "${context}" == "code" && -n "${MAKEVN_CODE_JAVA_HOME:-}" ]]; then
    printf '%s\n' "${MAKEVN_CODE_JAVA_HOME}"
    return 0
  fi

  if [[ "${context}" == "karate" && -n "${MAKEVN_KARATE_JAVA_HOME:-}" ]]; then
    printf '%s\n' "${MAKEVN_KARATE_JAVA_HOME}"
    return 0
  fi

  if [[ "${context}" == "karate" ]]; then
    tool_versions_file="${MAKEVN_KARATE_TOOL_VERSIONS:-}"
    if [[ -z "${tool_versions_file}" ]]; then
      tool_versions_file="$(makevn_detect_karate_tool_versions "${repo_root}" || true)"
    fi
  else
    tool_versions_file="${MAKEVN_CODE_TOOL_VERSIONS:-}"
    if [[ -z "${tool_versions_file}" ]]; then
      tool_versions_file="$(makevn_detect_code_tool_versions "${repo_root}" "${maven_base_path}" || true)"
    fi
  fi

  if [[ -n "${tool_versions_file}" ]]; then
    makevn_resolve_tool_versions_home "${tool_versions_file}"
    return 0
  fi

  if [[ -n "${MAKEVN_JAVA_HOME:-}" ]]; then
    printf '%s\n' "${MAKEVN_JAVA_HOME}"
    return 0
  fi

  if [[ "${context}" == "code" ]]; then
    local java_version=""
    makevn_load_profile "${repo_root}"
    java_version="${MAKEVN_PROFILE_CODE_JAVA_VERSION:-}"
    if [[ -z "${java_version}" ]]; then
      java_version="$(makevn_detect_java_version_from_pom "${maven_base_path}" || true)"
    fi
    if [[ -n "${java_version}" ]]; then
      local resolved_java_home=""
      if [[ "${MAKEVN_RESOLVE_COMPATIBLE_JAVA_FIRST:-}" == "1" ]]; then
        resolved_java_home="$(makevn_resolve_compatible_java_version_home "${java_version}" || true)"
        if [[ -n "${resolved_java_home}" ]]; then
          printf '%s\n' "${resolved_java_home}"
          return 0
        fi
      fi
      resolved_java_home="$(makevn_resolve_java_version_home "${java_version}" || true)"
      if [[ -n "${resolved_java_home}" ]]; then
        printf '%s\n' "${resolved_java_home}"
        return 0
      fi
      if [[ "${MAKEVN_RESOLVE_COMPATIBLE_JAVA_FIRST:-}" != "1" ]]; then
        resolved_java_home="$(makevn_resolve_compatible_java_version_home "${java_version}" || true)"
        if [[ -n "${resolved_java_home}" ]]; then
          printf '%s\n' "${resolved_java_home}"
          return 0
        fi
      fi
    fi
  fi

  return 1
}

makevn_java_version_line() {
  local java_home="$1"
  "${java_home}/bin/java" -version 2>&1 | sed -n '1p'
}

makevn_maven_executable() {
  local repo_root="$1"
  local maven_base_path="$2"

  if [[ -x "${repo_root}/mvnw" ]]; then
    printf '%s\n' "${repo_root}/mvnw"
    return 0
  fi

  if [[ -n "${maven_base_path}" && -x "${maven_base_path}/mvnw" ]]; then
    printf '%s\n' "${maven_base_path}/mvnw"
    return 0
  fi

  printf '%s\n' mvn
}

makevn_run_in_context() {
  local repo_root="$1"
  local context="$2"
  local maven_base_path="$3"
  local java_home=""

  shift 3

  java_home="$(makevn_effective_java_home "${repo_root}" "${context}" "${maven_base_path}" || true)"
  if [[ -z "${java_home}" ]]; then
    if [[ "${context}" == "code" ]]; then
      local java_version=""
      makevn_load_profile "${repo_root}"
      java_version="${MAKEVN_PROFILE_CODE_JAVA_VERSION:-}"
      if [[ -z "${java_version}" ]]; then
        java_version="$(makevn_detect_java_version_from_pom "${maven_base_path}" || true)"
      fi
      if [[ -n "${java_version}" ]]; then
        local resolution_hint=""
        resolution_hint="$(makevn_compatible_java_resolution_hint "${java_version}" || true)"
        if [[ -n "${resolution_hint}" ]]; then
          makevn_die "${resolution_hint}"
        fi
      fi
    fi
    makevn_die "Could not resolve ${context} JDK. Run 'makevn doctor' or configure .makevn/config first."
  fi

  makevn_trace_command exec env JAVA_HOME="${java_home}" "$@"

  (
    cd "${repo_root}"
    env JAVA_HOME="${java_home}" PATH="${java_home}/bin:${PATH}" "$@"
  )
}

makevn_maven_cli_flags_for_command() {
  local repo_root="$1"
  local command_name="$2"
  local maven_cli_flags_value=""
  local command_cli_flags_value=""

  makevn_load_profile "${repo_root}"
  maven_cli_flags_value="${MAKEVN_PROFILE_MAVEN_CLI_FLAGS:-}"
  if [[ -n "${command_name}" ]]; then
    command_cli_flags_value="$(makevn_command_profile_value "${command_name}" CLI_FLAGS || true)"
  fi

  printf '%s\n' "$(makevn_merge_words "${maven_cli_flags_value}" "${command_cli_flags_value}")"
}

makevn_maven_prop_flags_for_command() {
  local repo_root="$1"
  local command_name="$2"
  local maven_prop_flags_value=""
  local command_prop_flags_value=""

  makevn_load_profile "${repo_root}"
  maven_prop_flags_value="${MAKEVN_PROFILE_MAVEN_PROP_FLAGS:-}"
  if [[ -n "${command_name}" ]]; then
    command_prop_flags_value="$(makevn_command_profile_value "${command_name}" PROP_FLAGS || true)"
  fi

  printf '%s\n' "$(makevn_merge_words "${maven_prop_flags_value}" "${command_prop_flags_value}")"
}

makevn_maven_pre_goals_for_command() {
  local repo_root="$1"
  local command_name="$2"

  makevn_load_profile "${repo_root}"
  if [[ -n "${command_name}" ]]; then
    printf '%s\n' "$(makevn_command_profile_value "${command_name}" PRE_GOALS || true)"
    return 0
  fi

  printf '\n'
}

makevn_coverage_prop_flags() {
  local repo_root="$1"
  local detected_prop_flags=""

  makevn_load_config "${repo_root}"
  makevn_load_profile "${repo_root}"
  detected_prop_flags="${MAKEVN_PROFILE_COVERAGE_PROP_FLAGS:-}"
  printf '%s\n' "$(makevn_merge_words "${detected_prop_flags}" "${MAKEVN_COVERAGE_PROP_FLAGS:--Djacoco.skip=false}")"
}

makevn_coverage_cli_flags() {
  local repo_root="$1"

  makevn_load_profile "${repo_root}"
  printf '%s\n' "${MAKEVN_PROFILE_COVERAGE_CLI_FLAGS:-}"
}

makevn_append_coverage_prop_flags() {
  local repo_root="$1"
  local prop_flags_value="$2"
  local coverage_prop_flags=""
  local token=""

  coverage_prop_flags="$(makevn_coverage_prop_flags "${repo_root}")"
  for token in ${coverage_prop_flags}; do
    prop_flags_value="$(makevn_append_word "${prop_flags_value}" "${token}")"
  done
  printf '%s\n' "${prop_flags_value}"
}

makevn_append_coverage_cli_flags() {
  local repo_root="$1"
  local cli_flags_value="$2"
  local coverage_cli_flags=""
  local token=""

  coverage_cli_flags="$(makevn_coverage_cli_flags "${repo_root}")"
  for token in ${coverage_cli_flags}; do
    cli_flags_value="$(makevn_append_word "${cli_flags_value}" "${token}")"
  done
  printf '%s\n' "${cli_flags_value}"
}

makevn_test_log_token() {
  local token=""

  token="$(printf '%s' "$1" | tr '/ :,=' '_____' | tr -cd '[:alnum:]._-')"
  if [[ -n "${token}" ]]; then
    printf '%s\n' "${token}"
    return 0
  fi

  printf '%s\n' test
}

makevn_failsafe_summary_value() {
  local summary_path="$1"
  local element="$2"

  sed -nE "s/.*<${element}>([^<]+)<\\/${element}>.*/\\1/p" "${summary_path}" | head -n 1
}

makevn_verify_selected_failsafe_summary() {
  local maven_base_path="$1"
  local module_path="$2"
  local test_name="$3"
  local summary_path="${maven_base_path}/${module_path}/target/failsafe-reports/failsafe-summary.xml"
  local result=""
  local completed=""
  local errors=""
  local failures=""

  if [[ ! -f "${summary_path}" ]]; then
    printf '%s\n' "$(makevn_warn "fail selected integration test did not produce a Failsafe summary: ${test_name}")" >&2
    return 1
  fi

  result="$(sed -nE 's/.*<failsafe-summary[^>]* result="([^"]+)".*/\1/p' "${summary_path}" | head -n 1)"
  completed="$(makevn_failsafe_summary_value "${summary_path}" completed)"
  errors="$(makevn_failsafe_summary_value "${summary_path}" errors)"
  failures="$(makevn_failsafe_summary_value "${summary_path}" failures)"
  completed="${completed:-0}"
  errors="${errors:-0}"
  failures="${failures:-0}"

  if [[ "${completed}" == "0" || "${errors}" != "0" || "${failures}" != "0" ]]; then
    printf '%s\n' "$(makevn_warn "fail selected integration test failed: ${test_name}")" >&2
    printf '%s\n' "$(makevn_dim "summary: ${summary_path}")" >&2
    return 1
  fi

  if [[ -n "${result}" && "${result}" != "0" && "${result}" != "null" ]]; then
    printf '%s\n' "$(makevn_warn "fail selected integration test failed: ${test_name}")" >&2
    printf '%s\n' "$(makevn_dim "summary: ${summary_path}")" >&2
    return 1
  fi

  return 0
}

makevn_run_selected_test() {
  local repo_root="$1"
  local test_name="$2"
  local fast_mode="$3"
  local maven_base_path=""
  local maven_executable=""
  local test_file=""
  local relative_test_file=""
  local module_path=""
  local module_base_path=""
  local package_name=""
  local full_test_class=""
  local boot_module=""
  local local_containers=""
  local cli_flags_value=""
  local prop_flags_value=""
  local log_name=""
  local title=""
  local test_param=""
  local test_mode="unit"
  local rc=0
  local -a cli_flags=()
  local -a prop_flags=()
  local -a maven_args=()

  shift 3
  makevn_load_profile "${repo_root}"
  local_containers="$(makevn_effective_local_containers "${repo_root}" "${MAKEVN_PROFILE_VERIFY_IT_LOCAL_CONTAINERS:-}")"

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if [[ -z "${maven_base_path}" ]]; then
    printf '%s\n' "$(makevn_warn "Error: No Maven project detected in ${repo_root}")" >&2
    return 1
  fi

  test_file="$(find "${maven_base_path}" -path '*/src/test/java/*' -name "${test_name}.java" -type f | LC_ALL=C sort | head -n 1 || true)"
  if [[ -z "${test_file}" ]]; then
    printf '%s\n' "$(makevn_warn "Error: test file not found: ${test_name}.java")" >&2
    return 1
  fi

  relative_test_file="${test_file#${maven_base_path}/}"
  if [[ "${relative_test_file}" == src/* ]]; then
    module_path=""
  elif [[ "${relative_test_file}" == */src/* ]]; then
    module_path="${relative_test_file%%/src/*}"
  else
    printf '%s\n' "$(makevn_warn "Error: could not detect module path for ${test_name}")" >&2
    return 1
  fi

  if [[ -n "${module_path}" ]]; then
    module_base_path="${maven_base_path}/${module_path}"
  else
    module_base_path="${maven_base_path}"
  fi
  package_name="$(sed -nE 's/^[[:space:]]*package[[:space:]]+([^;]+);[[:space:]]*$/\1/p' "${test_file}" | head -n 1)"
  if [[ -z "${package_name}" ]]; then
    printf '%s\n' "$(makevn_warn "Error: could not extract package from ${test_file}")" >&2
    return 1
  fi

  full_test_class="${package_name}.${test_name}"
  if [[ "${test_name}" == *IT ]] || grep -Eq '@SpringBootTest|@DataMongoTest|@WebMvcTest|@Testcontainers' "${test_file}"; then
    test_mode="integration"
    test_param="-Dit.test=${full_test_class}"
  else
    test_param="-Dtest=${full_test_class}"
  fi

  maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
  cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" test)"
  cli_flags_value="$(makevn_append_word "${cli_flags_value}" "-nsu")"
  prop_flags_value="$(makevn_maven_prop_flags_for_command "${repo_root}" test)"
  prop_flags_value="$(makevn_append_word "${prop_flags_value}" "${test_param}")"
  prop_flags_value="$(makevn_append_word "${prop_flags_value}" "-Dfailsafe.failIfNoSpecifiedTests=false")"
  prop_flags_value="$(makevn_append_word "${prop_flags_value}" "-Dsurefire.failIfNoSpecifiedTests=false")"
  prop_flags_value="$(makevn_append_word "${prop_flags_value}" "-Dmaven.build.cache.enabled=true")"

  if [[ "${test_mode}" == "integration" ]]; then
    boot_module="$(makevn_detect_boot_module_name "${repo_root}")"
    if [[ "${fast_mode}" == "true" ]]; then
      if [[ ! -d "${maven_base_path}/${boot_module}/target/classes" ]]; then
        printf '%s\n' "$(makevn_warn "Error: boot module not compiled (${boot_module}). Run 'makevn test --name ${test_name}' first.")" >&2
        return 1
      fi
      if [[ ! -d "${module_base_path}/target/test-classes" ]]; then
        printf '%s\n' "$(makevn_warn "Error: test classes not compiled for ${module_path:-root project}. Run 'makevn test --name ${test_name}' first.")" >&2
        return 1
      fi
      title="test ${test_name} --fast"
      log_name="test-fast-$(makevn_test_log_token "${test_name}")"
      if [[ -n "${local_containers}" ]]; then
        maven_args=(env "LOCAL_CONTAINERS=${local_containers}" "${maven_executable}")
      else
        maven_args=("${maven_executable}")
      fi
      if [[ -n "${cli_flags_value}" ]]; then
        read -r -a cli_flags <<< "${cli_flags_value}"
        maven_args+=("${cli_flags[@]}")
      fi
      maven_args+=(-f "${maven_base_path}/pom.xml")
      if [[ -n "${module_path}" ]]; then
        maven_args+=(-pl "${module_path}" -am)
      fi
      maven_args+=(failsafe:integration-test)
    else
      title="test ${test_name}"
      log_name="test-$(makevn_test_log_token "${test_name}")"
      if [[ -n "${local_containers}" ]]; then
        maven_args=(env "LOCAL_CONTAINERS=${local_containers}" "${maven_executable}")
      else
        maven_args=("${maven_executable}")
      fi
      if [[ -n "${cli_flags_value}" ]]; then
        read -r -a cli_flags <<< "${cli_flags_value}"
        maven_args+=("${cli_flags[@]}")
      fi
      maven_args+=(-f "${maven_base_path}/pom.xml")
      if [[ -n "${module_path}" ]]; then
        maven_args+=(-pl "${module_path}" -am)
      fi
      maven_args+=(test-compile failsafe:integration-test)
    fi
  else
    if [[ "${fast_mode}" == "true" ]]; then
      if [[ ! -d "${module_base_path}/target/test-classes" ]]; then
        printf '%s\n' "$(makevn_warn "Error: test classes not compiled for ${module_path:-root project}. Run 'makevn test --name ${test_name}' first.")" >&2
        return 1
      fi
      title="test ${test_name} --fast"
      log_name="test-fast-$(makevn_test_log_token "${test_name}")"
    else
      title="test ${test_name}"
      log_name="test-$(makevn_test_log_token "${test_name}")"
    fi

    maven_args=("${maven_executable}")
    if [[ -n "${cli_flags_value}" ]]; then
      read -r -a cli_flags <<< "${cli_flags_value}"
      maven_args+=("${cli_flags[@]}")
    fi
    maven_args+=(-f "${maven_base_path}/pom.xml")
    if [[ -n "${module_path}" ]]; then
      maven_args+=(-pl "${module_path}" -am)
    fi
    if [[ "${fast_mode}" == "true" ]]; then
      maven_args+=(surefire:test)
    else
      maven_args+=(test)
    fi
    prop_flags_value="$(makevn_append_word "${prop_flags_value}" "-Dsurefire.testFailureIgnore=false")"
  fi

  if [[ -n "${prop_flags_value}" ]]; then
    read -r -a prop_flags <<< "${prop_flags_value}"
    maven_args+=("${prop_flags[@]}")
  fi
  if [[ $# -gt 0 ]]; then
    maven_args+=("$@")
  fi

  if [[ "${test_mode}" == "integration" ]]; then
    rm -f "${maven_base_path}/${module_path}/target/failsafe-reports/failsafe-summary.xml"
  fi

  set +e
  MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" "${log_name}" test "${title}" "${maven_args[@]}"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    local logs_dir_hint
    logs_dir_hint="$(makevn_logs_dir "${repo_root}")"
    makevn_hint_stale_generated_sources_if_needed "${logs_dir_hint}/${log_name}.log"
    return ${rc}
  fi

  if [[ "${test_mode}" == "integration" ]]; then
    makevn_verify_selected_failsafe_summary "${maven_base_path}" "${module_path}" "${test_name}"
    return $?
  fi

  return 0
}

makevn_detect_verify_it_workflow_invocation() {
  local repo_root="$1"
  local workflows_root="${repo_root}/.github/workflows"
  local workflow_path=""
  local invocation=""
  local line=""
  local token=""
  local has_it_skip=false

  [[ -d "${workflows_root}" ]] || return 1

  while IFS= read -r workflow_path; do
    while IFS= read -r line; do
      invocation="$(makevn_extract_maven_invocation "${line}" || true)"
      [[ -n "${invocation}" ]] || continue
      [[ " ${invocation} " == *" install "* || " ${invocation} " == *" verify "* ]] || continue
      [[ " ${invocation} " == *" -DskipUTs "* || " ${invocation} " == *" -Dskip.unit.tests=true "* ]] || continue

      has_it_skip=false
      for token in ${invocation}; do
        if makevn_should_drop_verify_prop_flag "${token}"; then
          has_it_skip=true
          break
        fi
      done

      if [[ "${has_it_skip}" == false ]]; then
        printf '%s\n' "${invocation}"
        return 0
      fi
    done < "${workflow_path}"
  done < <(find "${workflows_root}" -type f \( -name '*integration*.yml' -o -name '*integration*.yaml' \) | LC_ALL=C sort)

  return 1
}

makevn_run_verify_it_goal() {
  local repo_root="$1"
  local log_name="$2"
  local maven_base_path=""
  local maven_executable=""
  local workflow_invocation=""
  local maven_cli_flags_value=""
  local maven_prop_flags_value=""
  local filtered_prop_flags_value=""
  local token=""
  local skip_next=false
  local local_containers=""
  local -a workflow_tokens=()
  local -a maven_cli_flags=()
  local -a filtered_prop_flags=()
  local -a maven_args=()

  shift 2

  makevn_load_profile "${repo_root}"
  local_containers="$(makevn_effective_local_containers "${repo_root}" "${MAKEVN_PROFILE_VERIFY_IT_LOCAL_CONTAINERS:-}")"

  workflow_invocation="$(makevn_detect_verify_it_workflow_invocation "${repo_root}" || true)"
  if [[ -n "${workflow_invocation}" ]]; then
    maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
    if [[ -z "${maven_base_path}" ]]; then
      makevn_die "No Maven project detected in ${repo_root}"
    fi

    maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
    read -r -a workflow_tokens <<< "${workflow_invocation}"

    if [[ -n "${local_containers}" ]]; then
      maven_args=(env "LOCAL_CONTAINERS=${local_containers}" "${maven_executable}" -f "${maven_base_path}/pom.xml")
    else
      maven_args=("${maven_executable}" -f "${maven_base_path}/pom.xml")
    fi
    for token in "${workflow_tokens[@]:1}"; do
      if [[ "${skip_next}" == true ]]; then
        skip_next=false
        continue
      fi

      case "${token}" in
        -f|--file)
          skip_next=true
          ;;
        -DskipIT|-DskipIT=*|-DskipITs|-DskipITs=*|-DskipITests|-DskipITests=*|-DskipIntegrationTests|-DskipIntegrationTests=*|-DskipFailsafeTests|-DskipFailsafeTests=*|-Dmaven.failsafe.skip|-Dmaven.failsafe.skip=*|-Dmaven.build.cache.enabled|-Dmaven.build.cache.enabled=*)
          ;;
        install)
          maven_args+=(verify)
          ;;
        *)
          maven_args+=("${token}")
          ;;
      esac
    done
    maven_args+=(-Dmaven.build.cache.enabled=false)
    if [[ $# -gt 0 ]]; then
      maven_args+=("$@")
    fi

    MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" "${log_name}" verify-it "${log_name}" "${maven_args[@]}"
    return 0
  fi

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if [[ -z "${maven_base_path}" ]]; then
    makevn_die "No Maven project detected in ${repo_root}"
  fi

  maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
  maven_cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" verify)"
  maven_prop_flags_value="$(makevn_maven_prop_flags_for_command "${repo_root}" verify)"

  for token in ${maven_prop_flags_value}; do
    if ! makevn_should_drop_maven_cache_prop_flag "${token}"; then
      filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "${token}")"
    fi
  done

  filtered_prop_flags_value="$(makevn_append_coverage_prop_flags "${repo_root}" "${filtered_prop_flags_value}")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-DskipUTs")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-Dskip.unit.tests=true")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-DfailIfNoTests=false")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-Dmaven.test.failure.ignore=false")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-Dmaven.build.cache.enabled=false")"

  if [[ -n "${local_containers}" ]]; then
    maven_args=(env "LOCAL_CONTAINERS=${local_containers}" "${maven_executable}")
  else
    maven_args=("${maven_executable}")
  fi
  if [[ -n "${maven_cli_flags_value}" ]]; then
    read -r -a maven_cli_flags <<< "${maven_cli_flags_value}"
    maven_args+=("${maven_cli_flags[@]}")
  fi
  maven_args+=(-f "${maven_base_path}/pom.xml" verify)
  if [[ -n "${filtered_prop_flags_value}" ]]; then
    read -r -a filtered_prop_flags <<< "${filtered_prop_flags_value}"
    maven_args+=("${filtered_prop_flags[@]}")
  fi
  if [[ $# -gt 0 ]]; then
    maven_args+=("$@")
  fi

  MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" "${log_name}" verify-it "${log_name}" "${maven_args[@]}"
}

makevn_run_maven_goal() {
  local repo_root="$1"
  local goal="$2"
  local log_name="$3"
  local command_name="$4"
  local maven_base_path
  local maven_executable
  local maven_cli_flags_value=""
  local maven_prop_flags_value=""
  local command_cli_flags_value=""
  local command_prop_flags_value=""
  local command_pre_goals_value=""
  local maven_cli_flags=()
  local maven_prop_flags=()
  local command_pre_goals=()
  local maven_args=()

  shift 4

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if [[ -z "${maven_base_path}" ]]; then
    makevn_die "No Maven project detected in ${repo_root}"
  fi

  maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
  maven_cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" "${command_name}")"
  maven_prop_flags_value="$(makevn_maven_prop_flags_for_command "${repo_root}" "${command_name}")"
  command_pre_goals_value="$(makevn_maven_pre_goals_for_command "${repo_root}" "${command_name}")"
  if [[ -n "${maven_cli_flags_value}" ]]; then
    read -r -a maven_cli_flags <<< "${maven_cli_flags_value}"
  fi
  if [[ -n "${maven_prop_flags_value}" ]]; then
    read -r -a maven_prop_flags <<< "${maven_prop_flags_value}"
  fi
  if [[ -n "${command_pre_goals_value}" ]]; then
    read -r -a command_pre_goals <<< "${command_pre_goals_value}"
  fi

  maven_args=("${maven_executable}")
  if [[ ${#maven_cli_flags[@]} -gt 0 ]]; then
    maven_args+=("${maven_cli_flags[@]}")
  fi
  maven_args+=(-f "${maven_base_path}/pom.xml")
  if [[ ${#command_pre_goals[@]} -gt 0 ]]; then
    maven_args+=("${command_pre_goals[@]}")
  fi
  maven_args+=("${goal}")
  if [[ ${#maven_prop_flags[@]} -gt 0 ]]; then
    maven_args+=("${maven_prop_flags[@]}")
  fi
  if [[ $# -gt 0 ]]; then
    maven_args+=("$@")
  fi

  MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" "${log_name}" "${command_name}" "${log_name}" "${maven_args[@]}"
}

makevn_run_command_configured() {
  local repo_root="$1"
  local maven_base_path="$2"

  makevn_load_config "${repo_root}"
  if [[ -z "${MAKEVN_RUN_CMD:-}" ]]; then
    makevn_die "No run command configured. Set MAKEVN_RUN_CMD in .makevn/config first."
  fi

  makevn_run_in_context "${repo_root}" code "${maven_base_path}" bash -lc "${MAKEVN_RUN_CMD}"
}
