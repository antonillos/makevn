#!/usr/bin/env bash
set -euo pipefail

makevn_effective_coverage_threshold() {
  local repo_root="$1"

  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_MIN_COVERAGE_THRESHOLD:-}" ]]; then
    printf '%s\n' "${MAKEVN_MIN_COVERAGE_THRESHOLD}"
    return 0
  fi

  makevn_load_profile "${repo_root}"
  if [[ -n "${MAKEVN_PROFILE_COVERAGE_THRESHOLD:-}" ]]; then
    printf '%s\n' "${MAKEVN_PROFILE_COVERAGE_THRESHOLD}"
    return 0
  fi

  printf '%s\n' "90"
}

makevn_effective_coverage_changes_threshold() {
  local repo_root="$1"

  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD:-}" ]]; then
    printf '%s\n' "${MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD}"
    return 0
  fi

  makevn_load_profile "${repo_root}"
  if [[ -n "${MAKEVN_PROFILE_COVERAGE_CHANGES_THRESHOLD:-}" ]]; then
    printf '%s\n' "${MAKEVN_PROFILE_COVERAGE_CHANGES_THRESHOLD}"
    return 0
  fi

  printf '%s\n' "90"
}

makevn_jacoco_csv_has_classes() {
  local csv_path="$1"

  [[ -f "${csv_path}" ]] || return 1
  awk 'NR > 1 && $0 !~ /^[[:space:]]*$/ { found=1; exit } END { exit found ? 0 : 1 }' "${csv_path}"
}

makevn_require_jacoco_csv_classes() {
  local csv_path="$1"

  if ! makevn_jacoco_csv_has_classes "${csv_path}"; then
    makevn_die "JaCoCo report contains no classes or execution data: ${csv_path}. Run 'makevn profile refresh' after changing coverage configuration, then run a coverage-enabled verify flow such as 'makevn verify-ut-coverage' or 'makevn verify-it-coverage' before coverage analysis."
  fi
}

makevn_write_coverage_frontend_metadata() {
  local repo_root="$1"
  local maven_base_path="$2"

  makevn_write_backend_metadata \
    "${MAKEVN_BACKEND_METADATA_OUT:-}" \
    "coverage" \
    "${repo_root}" \
    "${maven_base_path}" \
    "" \
    "" \
    "makevn coverage" \
    "" \
    "coverage"
}

makevn_count_non_empty_lines() {
  local value="$1"

  printf '%s\n' "${value}" | sed '/^$/d' | wc -l | tr -d '[:space:]'
}

makevn_verify_changes_plan_path() {
  local repo_root="$1"

  printf '%s/verify-changes-plan.env\n' "$(makevn_state_dir "${repo_root}")"
}

makevn_clear_verify_changes_plan() {
  local repo_root="$1"
  local plan_path=""

  plan_path="$(makevn_verify_changes_plan_path "${repo_root}")"
  [[ -f "${plan_path}" ]] && rm -f "${plan_path}"
}

makevn_write_verify_changes_plan() {
  local repo_root="$1"
  local plan_path=""
  local tmp_path=""

  plan_path="$(makevn_verify_changes_plan_path "${repo_root}")"
  mkdir -p "$(makevn_state_dir "${repo_root}")"
  tmp_path="$(mktemp "${plan_path}.tmp.XXXXXX")"

  {
    printf 'MAKEVN_VERIFY_CHANGES_CACHE_CREATED_AT=%q\n' "$(date +%s)"
    printf 'MAKEVN_VERIFY_CHANGES_CACHE_HEAD=%q\n' "$(git -C "${repo_root}" rev-parse HEAD)"
    printf 'MAKEVN_VERIFY_CHANGES_PARENT_SPEC=%q\n' "${MAKEVN_VERIFY_CHANGES_PARENT_SPEC}"
    printf 'MAKEVN_VERIFY_CHANGES_DIFF_LOCAL=%q\n' "${MAKEVN_VERIFY_CHANGES_DIFF_LOCAL}"
    printf 'MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH=%q\n' "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}"
    printf 'MAKEVN_VERIFY_CHANGES_MAVEN_BASE_REL=%q\n' "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_REL}"
    printf 'MAKEVN_VERIFY_CHANGES_MAVEN_EXECUTABLE=%q\n' "${MAKEVN_VERIFY_CHANGES_MAVEN_EXECUTABLE}"
    printf 'MAKEVN_VERIFY_CHANGES_LOCAL_CONTAINERS=%q\n' "${MAKEVN_VERIFY_CHANGES_LOCAL_CONTAINERS}"
    printf 'MAKEVN_VERIFY_CHANGES_SRC_FILES=%q\n' "${MAKEVN_VERIFY_CHANGES_SRC_FILES}"
    printf 'MAKEVN_VERIFY_CHANGES_TEST_FILES=%q\n' "${MAKEVN_VERIFY_CHANGES_TEST_FILES}"
    printf 'MAKEVN_VERIFY_CHANGES_MODULES=%q\n' "${MAKEVN_VERIFY_CHANGES_MODULES}"
    printf 'MAKEVN_VERIFY_CHANGES_CLASSES=%q\n' "${MAKEVN_VERIFY_CHANGES_CLASSES}"
    printf 'MAKEVN_VERIFY_CHANGES_MODULE_SELECTION=%q\n' "${MAKEVN_VERIFY_CHANGES_MODULE_SELECTION}"
    printf 'MAKEVN_VERIFY_CHANGES_TEST_LIST=%q\n' "${MAKEVN_VERIFY_CHANGES_TEST_LIST}"
  } > "${tmp_path}"

  mv "${tmp_path}" "${plan_path}"
}

makevn_load_verify_changes_plan() {
  local repo_root="$1"
  local plan_path=""
  local current_head=""
  local current_parent_spec=""
  local current_diff_local=""

  plan_path="$(makevn_verify_changes_plan_path "${repo_root}")"
  [[ -f "${plan_path}" ]] || return 1

  # shellcheck source=/dev/null
  source "${plan_path}"

  current_head="$(git -C "${repo_root}" rev-parse HEAD)"
  current_parent_spec="$(makevn_detect_parent_branch_spec "${repo_root}")"
  current_diff_local="$(git -C "${repo_root}" diff --name-only HEAD || true)"

  if [[ "${MAKEVN_VERIFY_CHANGES_CACHE_HEAD:-}" != "${current_head}" ]] \
    || [[ "${MAKEVN_VERIFY_CHANGES_PARENT_SPEC:-}" != "${current_parent_spec}" ]] \
    || [[ "${MAKEVN_VERIFY_CHANGES_DIFF_LOCAL:-}" != "${current_diff_local}" ]]; then
    makevn_clear_verify_changes_plan "${repo_root}"
    return 1
  fi

  return 0
}

makevn_collect_verify_changes_scope() {
  local repo_root="$1"
  local local_containers=""
  local diff_base=""
  local diff_local=""
  local git_root=""
  local jacoco_module=""
  local maven_git_rel=""
  local path_prefix_regex=""
  local physical_git_root=""
  local physical_maven_base_path=""
  local strip_prefix=""

  MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" ]] || makevn_die "No Maven project detected in ${repo_root}"

  if [[ "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" == "${repo_root}" ]]; then
    MAKEVN_VERIFY_CHANGES_MAVEN_BASE_REL='.'
  else
    MAKEVN_VERIFY_CHANGES_MAVEN_BASE_REL="${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH#${repo_root}/}"
  fi

  MAKEVN_VERIFY_CHANGES_MAVEN_EXECUTABLE="$(makevn_maven_executable "${repo_root}" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}")"
  local_containers="$(makevn_effective_local_containers "${repo_root}" "${MAKEVN_PROFILE_VERIFY_IT_LOCAL_CONTAINERS:-}")"
  MAKEVN_VERIFY_CHANGES_LOCAL_CONTAINERS="${local_containers}"

  git -C "${repo_root}" rev-parse HEAD >/dev/null 2>&1 || makevn_die "Not a git repository"
  git_root="$(git -C "${repo_root}" rev-parse --show-toplevel)"
  physical_git_root="$(cd "${git_root}" && pwd -P)"
  physical_maven_base_path="$(cd "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" && pwd -P)"
  if [[ "${physical_maven_base_path}" == "${physical_git_root}" ]]; then
    path_prefix_regex='^'
    strip_prefix=''
  else
    maven_git_rel="${physical_maven_base_path#${physical_git_root}/}"
    path_prefix_regex="^${maven_git_rel}/"
    strip_prefix="${maven_git_rel}/"
  fi

  MAKEVN_VERIFY_CHANGES_PARENT_SPEC="$(makevn_detect_parent_branch_spec "${repo_root}")"
  if [[ "${MAKEVN_VERIFY_CHANGES_PARENT_SPEC}" == "HEAD" ]]; then
    diff_local="$(git -C "${git_root}" diff --name-only HEAD || true)"
    MAKEVN_VERIFY_CHANGES_DIFF_LOCAL="${diff_local}"
    MAKEVN_VERIFY_CHANGES_SRC_FILES="$(printf '%s\n' "${diff_local}" | grep -E "${path_prefix_regex}.*src/main/java/.*\.java$" || true)"
    MAKEVN_VERIFY_CHANGES_TEST_FILES="$(printf '%s\n' "${diff_local}" | grep -E "${path_prefix_regex}.*src/test/java/.*\.java$" || true)"
  else
    diff_base="$(git -C "${git_root}" diff --name-only "${MAKEVN_VERIFY_CHANGES_PARENT_SPEC}" || true)"
    diff_local="$(git -C "${git_root}" diff --name-only HEAD || true)"
    MAKEVN_VERIFY_CHANGES_DIFF_LOCAL="${diff_local}"
    MAKEVN_VERIFY_CHANGES_SRC_FILES="$(printf '%s\n%s\n' "${diff_base}" "${diff_local}" | grep -E "${path_prefix_regex}.*src/main/java/.*\.java$" | LC_ALL=C sort -u || true)"
    MAKEVN_VERIFY_CHANGES_TEST_FILES="$(printf '%s\n%s\n' "${diff_base}" "${diff_local}" | grep -E "${path_prefix_regex}.*src/test/java/.*\.java$" | LC_ALL=C sort -u || true)"
  fi

  MAKEVN_VERIFY_CHANGES_MODULES=''
  MAKEVN_VERIFY_CHANGES_CLASSES=''
  MAKEVN_VERIFY_CHANGES_MODULE_SELECTION=''
  if [[ -n "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" ]]; then
    MAKEVN_VERIFY_CHANGES_MODULES="$(printf '%s\n' "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" | sed "s|^${strip_prefix}||" | sed 's|/src/.*||' | sed 's|^src/.*||' | LC_ALL=C sort -u | sed '/^$/d' | paste -sd, -)"
    MAKEVN_VERIFY_CHANGES_CLASSES="$(printf '%s\n' "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" | sed 's|^.*src/main/java/||' | sed 's|\.java$||' | tr '/' '.' | paste -sd, -)"
    if [[ -n "${MAKEVN_VERIFY_CHANGES_MODULES}" ]]; then
      jacoco_module="$(makevn_detect_jacoco_module_name "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" || true)"
      MAKEVN_VERIFY_CHANGES_MODULE_SELECTION="${MAKEVN_VERIFY_CHANGES_MODULES}"
      if [[ -n "${jacoco_module}" && ",${MAKEVN_VERIFY_CHANGES_MODULES}," != *",${jacoco_module},"* ]]; then
        MAKEVN_VERIFY_CHANGES_MODULE_SELECTION="${MAKEVN_VERIFY_CHANGES_MODULES},${jacoco_module}"
      fi
    fi
  fi

  MAKEVN_VERIFY_CHANGES_TEST_LIST=''
  if [[ -n "${MAKEVN_VERIFY_CHANGES_TEST_FILES}" ]]; then
    MAKEVN_VERIFY_CHANGES_TEST_LIST="$(printf '%s\n' "${MAKEVN_VERIFY_CHANGES_TEST_FILES}" | sed "s|^${strip_prefix}||" | sed 's|^.*/src/test/java/||' | sed 's|\.java$||' | tr '/' '.' | paste -sd, -)"
  fi
}

makevn_print_verify_changes_preflight() {
  local command_name="$1"
  local strategy=""

  makevn_print_item "compare against" "${MAKEVN_VERIFY_CHANGES_PARENT_SPEC}"

  if [[ -z "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" && -z "${MAKEVN_VERIFY_CHANGES_TEST_FILES}" ]]; then
    makevn_print_item "strategy" "skip"
    makevn_print_detail_line "No modified Java files detected. Skipping ${command_name}."
    return 0
  fi

  if [[ -n "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" ]]; then
    makevn_print_item "production files" "$(makevn_count_non_empty_lines "${MAKEVN_VERIFY_CHANGES_SRC_FILES}")"
  fi
  if [[ -n "${MAKEVN_VERIFY_CHANGES_TEST_FILES}" ]]; then
    makevn_print_item "test files" "$(makevn_count_non_empty_lines "${MAKEVN_VERIFY_CHANGES_TEST_FILES}")"
  fi

  if [[ -n "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" ]]; then
    if [[ -n "${MAKEVN_VERIFY_CHANGES_MODULES}" ]]; then
      strategy="run verify for affected modules"
      makevn_print_item "modules" "${MAKEVN_VERIFY_CHANGES_MODULES}"
      makevn_print_item "verify selection" "${MAKEVN_VERIFY_CHANGES_MODULE_SELECTION}"
    else
      strategy="run full verify fallback"
    fi
    if [[ -n "${MAKEVN_VERIFY_CHANGES_CLASSES}" ]]; then
      makevn_print_item "classes" "${MAKEVN_VERIFY_CHANGES_CLASSES}"
    fi
  else
    strategy="run selected tests only"
    makevn_print_item "tests" "${MAKEVN_VERIFY_CHANGES_TEST_LIST}"
  fi

  makevn_print_item "strategy" "${strategy}"
}

cmd_verify_changes_preview() {
  local repo_root="$1"

  shift
  [[ $# -eq 0 ]] || makevn_die "verify-changes-preview does not accept extra arguments"

  if ! makevn_frontend_owns_loader; then
    print_command_intro "${repo_root}" verify-changes-preview
  fi

  makevn_load_profile "${repo_root}"
  makevn_collect_verify_changes_scope "${repo_root}"
  makevn_write_verify_changes_plan "${repo_root}"
  makevn_print_verify_changes_preflight "verify-changes-preview"
}

cmd_coverage() {
  local repo_root="$1"
  local maven_base_path=""
  local maven_executable=""
  local cli_flags_value=""
  local report_dirs=""
  local report_dir=""
  local threshold=""
  local calculate_script=""
  local csv_path=""
  local combined_csv=""
  local coverage_output=""
  local coverage_cli_flags_value=""
  local jacoco_plugin_declared=false
  local line=""
  local report_path=""
  local rc=0
  local -a cli_flags=()
  local -a report_args=()

  shift
  threshold="$(makevn_effective_coverage_threshold "${repo_root}")"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --threshold)
        [[ $# -ge 2 ]] || makevn_die "Missing value for --threshold"
        threshold="$2"
        shift 2
        ;;
      --)
        makevn_die "coverage does not accept Maven passthrough args"
        ;;
      *)
        makevn_die "Unknown coverage option: $1"
        ;;
    esac
  done

  print_command_intro "${repo_root}" coverage

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${maven_base_path}" ]] || makevn_die "No Maven project detected in ${repo_root}"
  makevn_write_coverage_frontend_metadata "${repo_root}" "${maven_base_path}"
  report_dirs="$(makevn_jacoco_report_dirs "${maven_base_path}" | sed '/^$/d' || true)"
  if [[ -z "${report_dirs}" ]]; then
    coverage_cli_flags_value="$(makevn_coverage_cli_flags "${repo_root}")"
    if [[ -n "${coverage_cli_flags_value}" ]]; then
      makevn_print_detail_line "Coverage report not found; detected coverage activation profile, running verify-ut coverage flow."
      cmd_verify_ut "${repo_root}"
      rc=$?
      [[ ${rc} -eq 0 ]] || return ${rc}
    else
      if makevn_repo_declares_jacoco_plugin "${maven_base_path}"; then
        jacoco_plugin_declared=true
      fi
      [[ "${jacoco_plugin_declared}" == true ]] || makevn_die "No JaCoCo activation or jacoco-maven-plugin declaration detected under ${maven_base_path}. Configure coverage in the repository, run 'makevn profile refresh', then run a coverage-enabled verify flow before 'makevn coverage'."
      makevn_print_detail_line "Coverage report not found; attempting jacoco:report from existing test data."
      maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
      cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" verify)"
      cli_flags_value="$(makevn_append_coverage_cli_flags "${repo_root}" "${cli_flags_value}")"
      cli_flags_value="$(makevn_append_word "${cli_flags_value}" "-nsu")"
      if [[ -n "${cli_flags_value}" ]]; then
        read -r -a cli_flags <<< "${cli_flags_value}"
      fi
      report_args=("${maven_executable}")
      if [[ ${#cli_flags[@]} -gt 0 ]]; then
        report_args+=("${cli_flags[@]}")
      fi
      report_args+=(-f "${maven_base_path}/pom.xml" jacoco:report -Dmaven.build.cache.enabled=false)
      MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" coverage-report coverage "coverage report" "${report_args[@]}"
      rc=$?
      [[ ${rc} -eq 0 ]] || return ${rc}
    fi
    makevn_write_coverage_frontend_metadata "${repo_root}" "${maven_base_path}"
    report_dirs="$(makevn_jacoco_report_dirs "${maven_base_path}" | sed '/^$/d' || true)"
  fi
  [[ -n "${report_dirs}" ]] || makevn_die "No JaCoCo report detected under ${maven_base_path}. Run 'makevn verify-ut-coverage' first."

  calculate_script="$(makevn_internal_make_script_path coverage/calculate.sh || true)"
  [[ -n "${calculate_script}" ]] || makevn_die "Internal coverage calculate runtime script not found"

  if [[ "$(printf '%s\n' "${report_dirs}" | sed '/^$/d' | wc -l | tr -d '[:space:]')" -eq 1 ]]; then
    report_dir="${report_dirs}"
    csv_path="${report_dir}/jacoco.csv"
  else
    combined_csv="$(mktemp "${TMPDIR:-/tmp}/makevn-jacoco-combined.XXXXXX.csv")"
    while IFS= read -r report_dir; do
      [[ -n "${report_dir}" ]] || continue
      [[ -f "${report_dir}/jacoco.csv" ]] || continue
      if [[ ! -s "${combined_csv}" ]]; then
        cat "${report_dir}/jacoco.csv" > "${combined_csv}"
      else
        tail -n +2 "${report_dir}/jacoco.csv" >> "${combined_csv}"
      fi
    done <<< "${report_dirs}"
    csv_path="${combined_csv}"
  fi
  [[ -f "${csv_path}" ]] || makevn_die "JaCoCo CSV report not found"
  makevn_require_jacoco_csv_classes "${csv_path}"

  set +e
  coverage_output="$(NO_COLOR=1 bash "${calculate_script}" "${csv_path}" "${threshold}" 2>&1)"
  rc=$?
  set -e
  [[ -z "${combined_csv}" ]] || rm -f "${combined_csv}"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    makevn_print_detail_line "${line}"
  done <<< "${coverage_output}"
  [[ ${rc} -eq 0 ]] || return ${rc}
  while IFS= read -r report_dir; do
    [[ -n "${report_dir}" ]] || continue
    report_path="${report_dir}/index.html"
    [[ -f "${report_path}" ]] && makevn_print_detail_line "Full report: ${report_path}"
  done <<< "${report_dirs}"
}

cmd_verify_changes() {
  local repo_root="$1"
  local cli_flags_value=""
  local prop_flags_value=""
  local log_name="verify-changes"
  local rc=0
  local -a cli_flags=()
  local -a prop_flags=()
  local -a extra_args
  local -a verify_args=()

  shift
  makevn_load_profile "${repo_root}"
  extra_args=()
  if [[ "${1:-}" == "--" ]]; then
    shift
    extra_args=("$@")
  elif [[ $# -gt 0 ]]; then
    makevn_die "verify-changes only accepts extra Maven args after '--'"
  fi

  if ! makevn_frontend_owns_loader; then
    print_command_intro "${repo_root}" verify-changes
  fi

  if ! makevn_load_verify_changes_plan "${repo_root}"; then
    makevn_collect_verify_changes_scope "${repo_root}"
  fi
  makevn_print_verify_changes_preflight "verify-changes"

  if [[ -z "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" && -z "${MAKEVN_VERIFY_CHANGES_TEST_FILES}" ]]; then
    makevn_clear_verify_changes_plan "${repo_root}"
    if makevn_frontend_owns_loader; then
      makevn_write_quick_backend_log \
        "${repo_root}" \
        "verify-changes" \
        "verify-changes" \
        "verify-changes" \
        "makevn verify-changes" \
        "compare against: ${MAKEVN_VERIFY_CHANGES_PARENT_SPEC}
strategy: skip
No modified Java files detected. Skipping verify-changes."
    fi
    return 0
  fi

  cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" verify)"
  cli_flags_value="$(makevn_append_word "${cli_flags_value}" "-nsu")"
  if [[ -n "${cli_flags_value}" ]]; then
    read -r -a cli_flags <<< "${cli_flags_value}"
  fi
  prop_flags_value="$(makevn_maven_prop_flags_for_command "${repo_root}" verify)"
  prop_flags_value="$(makevn_append_coverage_prop_flags "${repo_root}" "${prop_flags_value}")"
  if [[ -n "${prop_flags_value}" ]]; then
    read -r -a prop_flags <<< "${prop_flags_value}"
  fi

  if [[ -n "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" ]]; then
    if [[ -z "${MAKEVN_VERIFY_CHANGES_MODULES}" ]]; then
      makevn_clear_verify_changes_plan "${repo_root}"
      cmd_verify "${repo_root}"
      return $?
    fi

    verify_args=("${MAKEVN_VERIFY_CHANGES_MAVEN_EXECUTABLE}")
    if [[ ${#cli_flags[@]} -gt 0 ]]; then
      verify_args+=("${cli_flags[@]}")
    fi
    verify_args+=(-f "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}/pom.xml" -pl "${MAKEVN_VERIFY_CHANGES_MODULE_SELECTION}" -am verify)
    if [[ ${#prop_flags[@]} -gt 0 ]]; then
      verify_args+=("${prop_flags[@]}")
    fi
    verify_args+=(-DskipTests=false -Dmaven.test.failure.ignore=false -Dmaven.build.cache.enabled=false)
    if [[ ${#extra_args[@]} -gt 0 ]]; then
      verify_args+=("${extra_args[@]}")
    fi
    MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${log_name}" verify-changes "verify-changes" "${verify_args[@]}"
    rc=$?
    makevn_clear_verify_changes_plan "${repo_root}"
    [[ ${rc} -eq 0 ]] && makevn_print_jacoco_report_hint "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}"
    return ${rc}
  fi

  if [[ -n "${MAKEVN_VERIFY_CHANGES_LOCAL_CONTAINERS}" ]]; then
    verify_args=(env "LOCAL_CONTAINERS=${MAKEVN_VERIFY_CHANGES_LOCAL_CONTAINERS}" "${MAKEVN_VERIFY_CHANGES_MAVEN_EXECUTABLE}")
  else
    verify_args=("${MAKEVN_VERIFY_CHANGES_MAVEN_EXECUTABLE}")
  fi
  if [[ ${#cli_flags[@]} -gt 0 ]]; then
    verify_args+=("${cli_flags[@]}")
  fi
  verify_args+=(-f "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}/pom.xml" verify)
  if [[ ${#prop_flags[@]} -gt 0 ]]; then
    verify_args+=("${prop_flags[@]}")
  fi
  verify_args+=(-DskipUTs=false -Dtest="${MAKEVN_VERIFY_CHANGES_TEST_LIST}" -Dit.test="${MAKEVN_VERIFY_CHANGES_TEST_LIST}" -Dfailsafe.failIfNoSpecifiedTests=false -Dsurefire.failIfNoSpecifiedTests=false -Dawaitility.defaultPollInterval=200ms -Dawaitility.defaultTimeout=2m -Dmaven.build.cache.enabled=false)
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    verify_args+=("${extra_args[@]}")
  fi
  MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${log_name}" verify-changes "verify-changes" "${verify_args[@]}"
  rc=$?
  makevn_clear_verify_changes_plan "${repo_root}"
  [[ ${rc} -eq 0 ]] && makevn_print_jacoco_report_hint "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}"
  return ${rc}
}

cmd_coverage_changes() {
  local repo_root="$1"
  local maven_base_path=""
  local maven_base_rel=""
  local git_root=""
  local physical_git_root=""
  local physical_maven_base_path=""
  local maven_executable=""
  local report_dir=""
  local jacoco_module=""
  local parent_spec=""
  local threshold=""
  local overall_threshold=""
  local verbose=false
  local coverage_script=""
  local coverage_output=""
  local coverage_output_file=""
  local line=""
  local cli_flags_value=""
  local prop_flags_value=""
  local rc=0
  local -a cli_flags=()
  local -a prop_flags=()
  local -a report_args=()

  shift
  threshold="$(makevn_effective_coverage_changes_threshold "${repo_root}")"
  overall_threshold="$(makevn_effective_coverage_threshold "${repo_root}")"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --threshold)
        [[ $# -ge 2 ]] || makevn_die "Missing value for --threshold"
        threshold="$2"
        shift 2
        ;;
      --overall-threshold)
        [[ $# -ge 2 ]] || makevn_die "Missing value for --overall-threshold"
        overall_threshold="$2"
        shift 2
        ;;
      --verbose)
        verbose=true
        shift
        ;;
      --)
        makevn_die "coverage-changes does not accept Maven passthrough args; run verify-changes first if the report is missing"
        ;;
      *)
        makevn_die "Unknown coverage-changes option: $1"
        ;;
    esac
  done

  if ! makevn_frontend_owns_loader; then
    print_command_intro "${repo_root}" coverage-changes
  fi

  git -C "${repo_root}" rev-parse HEAD >/dev/null 2>&1 || makevn_die "Not a git repository"
  git_root="$(git -C "${repo_root}" rev-parse --show-toplevel)"

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${maven_base_path}" ]] || makevn_die "No Maven project detected in ${repo_root}"
  physical_git_root="$(cd "${git_root}" && pwd -P)"
  physical_maven_base_path="$(cd "${maven_base_path}" && pwd -P)"
  if [[ "${physical_maven_base_path}" == "${physical_git_root}" ]]; then
    maven_base_rel="."
  else
    maven_base_rel="${physical_maven_base_path#${physical_git_root}/}"
  fi

  report_dir="$(makevn_jacoco_report_dir "${maven_base_path}" || true)"
  [[ -n "${report_dir}" ]] || makevn_die "No JaCoCo aggregate module detected under ${maven_base_path}"

  if [[ ! -f "${report_dir}/index.html" ]]; then
    jacoco_module="$(makevn_detect_jacoco_module_name "${maven_base_path}" || true)"
    [[ -n "${jacoco_module}" ]] || makevn_die "No JaCoCo aggregate module detected under ${maven_base_path}"
    if [[ ! -d "${maven_base_path}/${jacoco_module}/target" ]]; then
      makevn_die "${jacoco_module} is not built. Run 'makevn verify' or 'makevn verify-changes' first."
    fi

    makevn_print_detail_line "Coverage report not found; attempting jacoco:report-aggregate for ${jacoco_module}."
    maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
    cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" verify)"
    cli_flags_value="$(makevn_append_coverage_cli_flags "${repo_root}" "${cli_flags_value}")"
    cli_flags_value="$(makevn_append_word "${cli_flags_value}" "-nsu")"
    if [[ -n "${cli_flags_value}" ]]; then
      read -r -a cli_flags <<< "${cli_flags_value}"
    fi
    prop_flags_value="$(makevn_maven_prop_flags_for_command "${repo_root}" verify)"
    prop_flags_value="$(makevn_append_coverage_prop_flags "${repo_root}" "${prop_flags_value}")"
    if [[ -n "${prop_flags_value}" ]]; then
      read -r -a prop_flags <<< "${prop_flags_value}"
    fi
    report_args=("${maven_executable}")
    if [[ ${#cli_flags[@]} -gt 0 ]]; then
      report_args+=("${cli_flags[@]}")
    fi
    report_args+=(-f "${maven_base_path}/pom.xml" jacoco:report-aggregate -pl "${jacoco_module}")
    if [[ ${#prop_flags[@]} -gt 0 ]]; then
      report_args+=("${prop_flags[@]}")
    fi
    report_args+=(-Dmaven.build.cache.enabled=false)
    MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" coverage-changes-report coverage-changes "coverage report" "${report_args[@]}"
    rc=$?
    [[ ${rc} -eq 0 ]] || return ${rc}
    [[ -f "${report_dir}/index.html" ]] || makevn_die "Could not generate JaCoCo report. Run 'makevn verify' first."
  fi

  makevn_require_jacoco_csv_classes "${report_dir}/jacoco.csv"

  parent_spec="$(makevn_detect_parent_branch_spec "${repo_root}")"

  coverage_script="$(makevn_internal_make_script_path coverage/changes.sh || true)"
  [[ -n "${coverage_script}" ]] || makevn_die "Internal coverage changes runtime script not found"

  coverage_output_file="$(mktemp "${TMPDIR:-/tmp}/makevn-coverage-changes.XXXXXX")"
  set +e
  (
    cd "${git_root}" && BASE_PATH="${maven_base_rel}" COVERAGE_VERBOSE="${verbose}" bash "${coverage_script}" "${report_dir}" "${parent_spec}" "${threshold}" "${overall_threshold}"
  ) > "${coverage_output_file}" 2>&1
  rc=$?
  set -e
  coverage_output="$(cat "${coverage_output_file}" || true)"
  rm -f "${coverage_output_file}"
  while IFS= read -r line; do
    makevn_print_detail_line "${line}"
  done <<< "${coverage_output}"
  return ${rc}
}
