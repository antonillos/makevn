#!/usr/bin/env bash

makevn_changes_mode() {
  MAKEVN_VERIFY_CHANGES_MODE=exhaustive
  MAKEVN_VERIFY_CHANGES_MODE_ARGS=0
  case "${1:-}" in
    --focused|--exhaustive)
      MAKEVN_VERIFY_CHANGES_MODE="${1#--}"
      MAKEVN_VERIFY_CHANGES_MODE_ARGS=1
      ;;
  esac
}

makevn_print_focused_changes_plan() {
  local owner tests
  makevn_print_item "mode" "focused (not a full integration or global coverage gate)"
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
  makevn_archive_selected_test "${repo_root}" "${phase}" "${rc}" "$((SECONDS - started))"
  exit "${rc}"
)

makevn_run_focused_changes() {
  local repo_root="$1" owner tests
  local MAKEVN_FOCUSED_PHASE_INDEX=1
  local -a base_args=("${verify_args[@]}" ${cli_flags[@]+"${cli_flags[@]}"} -f "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}/pom.xml" ${prop_flags[@]+"${prop_flags[@]}"} -Dmaven.build.cache.enabled=false -Dmaven.test.failure.ignore=false)
  # Install is necessary: verification without -am must consume this checkout's
  # freshly built dependencies, not older snapshots from another worktree.
  makevn_focused_changes_phase "${repo_root}" "prepare dependencies (no tests)" "${base_args[@]}" -pl "${MAKEVN_VERIFY_CHANGES_MODULE_SELECTION}" -am install -DskipTests=true -DskipUTs=true -DskipITs=true || return $?
  while IFS=$'\t' read -r owner tests; do
    [[ -n "${owner}" ]] || continue
    MAKEVN_FOCUSED_PHASE_INDEX=$((MAKEVN_FOCUSED_PHASE_INDEX + 1))
    makevn_verify_focused_owner "${repo_root}" "${owner}" "${tests}" "${base_args[@]}" || return $?
  done <<< "${MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN}"
}

makevn_verify_focused_owner() {
  local repo_root="$1" owner="$2" tests="$3"
  shift 3
  local stamp rc=0
  stamp="$(mktemp "$(makevn_state_dir "${repo_root}")/verify-changes-tests.XXXXXX")"
  local MAKEVN_FOCUSED_SELECTED_TESTS='' MAKEVN_FOCUSED_REPORT_STAMP="${stamp}" MAKEVN_FOCUSED_REPORT_MODULE="${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}/${owner}"
  local -a selection=()
  if [[ "${tests}" != '*' ]]; then
    MAKEVN_FOCUSED_SELECTED_TESTS="${tests}"
    selection=(-Dtest="${tests}" -Dit.test="${tests}" -Dsurefire.failIfNoSpecifiedTests=false -Dfailsafe.failIfNoSpecifiedTests=false)
  fi
  if makevn_focused_changes_phase "${repo_root}" "verify ${owner} (${tests})" "$@" -pl "${owner}" verify -DskipTests=false -DskipUTs=false -DskipITs=false ${selection[@]+"${selection[@]}"}; then rc=0; else rc=$?; fi
  rm -f "${stamp}"
  return "${rc}"
}

makevn_require_focused_test_reports() {
  [[ -n "${MAKEVN_FOCUSED_SELECTED_TESTS:-}" ]] || return 0
  python3 "${SCRIPT_DIR}/common/selected_test_reports.py" "${MAKEVN_FOCUSED_REPORT_MODULE}" "${MAKEVN_FOCUSED_SELECTED_TESTS}" "${MAKEVN_FOCUSED_REPORT_STAMP}"
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
