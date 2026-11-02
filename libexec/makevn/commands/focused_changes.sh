#!/usr/bin/env bash

source "${SCRIPT_DIR}/commands/test_impact.sh"
source "${SCRIPT_DIR}/commands/focused_coverage_gate.sh"

makevn_collect_focused_plan() {
  local changed_paths="$1" git_root="$2" comparison_base="$3" purpose="$4" rc=0
  local java_home
  java_home="$(makevn_effective_java_home "${git_root}" code "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}")" || java_home=''
  export MAKEVN_TEST_IMPACT_JAVA="${java_home}/bin/java"
  MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN="$(printf '%s\n' "${changed_paths}" | python3 "${SCRIPT_DIR}/common/changes_scope.py" "${git_root}" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${comparison_base}" --focused-plan)" || rc=$?
  if [[ "${rc}" == 3 && "${purpose}" == preview ]]; then
    MAKEVN_VERIFY_CHANGES_SCOPE_REQUIRED=true
    return 0
  fi
  [[ "${rc}" == 0 ]] || makevn_die "Focused planning did not produce a safe plan; inspect diagnostics before verification."
}

makevn_changes_mode() {
  MAKEVN_VERIFY_CHANGES_MODE=focused
  MAKEVN_VERIFY_CHANGES_MODE_ARGS=0
  export MAKEVN_TEST_IMPACT_CAPTURE=false
  MAKEVN_DEFER_GLOBAL_COVERAGE=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --record-test-impact) MAKEVN_TEST_IMPACT_CAPTURE=true ;;
      --defer-global-coverage) MAKEVN_DEFER_GLOBAL_COVERAGE=true ;;
      --focused|--exhaustive)
      MAKEVN_VERIFY_CHANGES_MODE="${1#--}"
      ;;
      *) break ;;
    esac
    MAKEVN_VERIFY_CHANGES_MODE_ARGS=$((MAKEVN_VERIFY_CHANGES_MODE_ARGS + 1))
    shift
  done
  [[ "${MAKEVN_TEST_IMPACT_CAPTURE}" != true || "${MAKEVN_VERIFY_CHANGES_MODE}" == focused ]] || makevn_die "--record-test-impact requires focused mode"
  makevn_validate_deferred_global_coverage
}

makevn_print_focused_changes_plan() {
  local owner tests
  makevn_print_item "mode" "focused (not a full integration or global coverage gate)"
  makevn_print_deferred_global_coverage
  makevn_print_item "selection" "validated test-impact evidence when available; otherwise complete owner module suites with fallback reasons"
  if [[ "${MAKEVN_TEST_IMPACT_CAPTURE:-false}" == true ]]; then
    makevn_print_item "test impact capture" "complete suite followed by isolated per-test-class verification; JDK 17+ and standard single-module Java layout required"
  fi
  makevn_print_item "prepare" "${MAKEVN_VERIFY_CHANGES_MODULE_SELECTION} plus dependencies: install without UT/IT; updates local Maven artifacts"
  while IFS=$'\t' read -r owner tests; do
    [[ -n "${owner}" ]] || continue
    makevn_print_item "verify ${owner}" "${tests/\*/entire module suite}; without -am"
  done <<< "${MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN}"
}

makevn_focused_changes_phase() (
  local repo_root="$1" phase="$2" started="${SECONDS}" rc=0
  shift 2
  local index="${MAKEVN_FOCUSED_PHASE_INDEX}"
  [[ -z "${MAKEVN_BACKEND_METADATA_OUT:-}" ]] || : > "${MAKEVN_BACKEND_METADATA_OUT}"
  [[ -z "${MAKEVN_BACKEND_DETAIL_OUT:-}" ]] || : > "${MAKEVN_BACKEND_DETAIL_OUT}"
  if MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "verify-changes-${index}" verify-changes "${phase}" "$@"; then rc=0; else rc=$?; fi
  if [[ "${rc}" == 0 ]]; then
    makevn_require_focused_test_reports || rc=$?
  fi
  makevn_archive_selected_test "${repo_root}" "${phase}" "${rc}" "$((SECONDS - started))" verify-changes
  exit "${rc}"
)

makevn_run_focused_changes() (
  local repo_root="$1" owner tests
  local MAKEVN_FOCUSED_PHASE_INDEX=1
  makevn_focused_coverage_gate_flags
  local -a base_args=("${verify_args[@]}" ${cli_flags[@]+"${cli_flags[@]}"} -f "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}/pom.xml" ${prop_flags[@]+"${prop_flags[@]}"} -Dmaven.build.cache.enabled=false -Dmaven.test.failure.ignore=false ${MAKEVN_FOCUSED_COVERAGE_GATE_FLAGS[@]+"${MAKEVN_FOCUSED_COVERAGE_GATE_FLAGS[@]}"})
  # Install is necessary: verification without -am must consume this checkout's
  # freshly built dependencies, not older snapshots from another worktree.
  makevn_focused_changes_phase "${repo_root}" "prepare dependencies (no tests)" "${base_args[@]}" -pl "${MAKEVN_VERIFY_CHANGES_MODULE_SELECTION}" -am install -DskipTests=true -DskipUTs=true -DskipITs=true || return $?
  makevn_scoped_coverage_checkpoint "${repo_root}" || return $?
  makevn_validate_prepared_impact "${repo_root}" || return $?
  local capture_stamp
  capture_stamp="$(mktemp "$(makevn_state_dir "${repo_root}")/impact-suite.XXXXXX")"
  trap 'rm -f "${capture_stamp}"' EXIT
  while IFS=$'\t' read -r owner tests; do
    [[ -n "${owner}" ]] || continue
    MAKEVN_FOCUSED_PHASE_INDEX=$((MAKEVN_FOCUSED_PHASE_INDEX + 1))
    makevn_verify_focused_owner "${repo_root}" "${owner}" "${tests}" "${base_args[@]}" || return $?
  done <<< "${MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN}"
  makevn_capture_test_impact "${repo_root}" "${capture_stamp}" "${base_args[@]}"
)

makevn_verify_focused_owner() {
  local repo_root="$1" owner="$2" tests="$3"
  shift 3
  makevn_focused_test_selection "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}/${owner}" "${tests}" || return $?
  local stamp rc=0
  stamp="$(mktemp "$(makevn_state_dir "${repo_root}")/verify-changes-tests.XXXXXX")"
  local MAKEVN_FOCUSED_SELECTED_TESTS='' MAKEVN_FOCUSED_REPORT_STAMP="${stamp}" MAKEVN_FOCUSED_REPORT_MODULE="${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}/${owner}"
  if [[ "${tests}" != '*' ]]; then
    MAKEVN_FOCUSED_SELECTED_TESTS="${tests}"
  fi
  if makevn_focused_changes_phase "${repo_root}" "verify ${owner} (${tests})" "$@" -pl "${owner}" verify -DskipTests=false -DskipUTs=false -DskipITs=false ${MAKEVN_FOCUSED_SELECTION[@]+"${MAKEVN_FOCUSED_SELECTION[@]}"}; then rc=0; else rc=$?; fi
  rm -f "${stamp}"
  return "${rc}"
}

makevn_focused_test_selection() {
  MAKEVN_FOCUSED_SELECTION=()
  [[ "$2" != '*' ]] || return 0
  local flags flag
  flags="$(python3 "${SCRIPT_DIR}/common/selected_test_reports.py" --flags "$1" "$2")" || return $?
  while IFS= read -r flag; do MAKEVN_FOCUSED_SELECTION+=("${flag}"); done <<< "${flags}"
}

makevn_require_focused_test_reports() {
  [[ -n "${MAKEVN_FOCUSED_SELECTED_TESTS:-}" ]] || return 0
  python3 "${SCRIPT_DIR}/common/selected_test_reports.py" "${MAKEVN_FOCUSED_REPORT_MODULE}" "${MAKEVN_FOCUSED_SELECTED_TESTS}" "${MAKEVN_FOCUSED_REPORT_STAMP}" "${repo_root}"
}

makevn_validate_focused_flags() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      -am|--also-make|-amd|--also-make-dependents|-pl*|--projects*|-f|--file*|-rf*|--resume-from*|-N|--non-recursive|-Dtest*|-Dit.test*|-Dmaven.test.skip*)
        makevn_die "Focused verification cannot honor scope-changing configured flag ${arg}; use --exhaustive."
        ;;
    esac
  done
}
