#!/usr/bin/env bash

makevn_capture_impact_class() (
  local repo_root="$1" name="$2" traces
  shift 2
  traces="$(mktemp -d "$(makevn_state_dir "${repo_root}")/test-impact/traces.XXXXXX")"
  trap 'rm -rf "${traces}"' EXIT
  [[ "${1:-}" != env ]] || shift
  local MAKEVN_TEST_IMPACT_REPLAY_GOAL=verify
  case "${name##*.}" in IT*|*IT|*ITCase) ;; *) MAKEVN_TEST_IMPACT_REPLAY_GOAL=test ;; esac
  makevn_verify_focused_owner "${repo_root}" . "${name}" env "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS:-} \"-Xlog:class+load=info:file=${traces}/%p.log\"" "$@" || return $?
  python3 "${SCRIPT_DIR}/common/test_impact.py" record "${repo_root}" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${name}" "${traces}"
)

makevn_capture_test_impact() {
  [[ "${MAKEVN_TEST_IMPACT_CAPTURE:-false}" == true ]] || return 0
  local repo_root="$1" stamp="$2" java_home tests name
  shift 2
  java_home="$(makevn_effective_java_home "${repo_root}" code "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}")" || return $?
  tests="$(python3 "${SCRIPT_DIR}/common/test_impact.py" begin "${repo_root}" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${java_home}/bin/java" "${stamp}")" || return $?
  makevn_print_item "test impact capture" "isolating missing test classes; compatible completed records are reused"
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    MAKEVN_FOCUSED_PHASE_INDEX=$((MAKEVN_FOCUSED_PHASE_INDEX + 1))
    makevn_capture_impact_class "${repo_root}" "${name}" "$@" || return $?
  done <<< "${tests}"
  python3 "${SCRIPT_DIR}/common/test_impact.py" finish "${repo_root}" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${java_home}/bin/java"
}

makevn_finish_test_impact_capture() {
  [[ "${MAKEVN_TEST_IMPACT_CAPTURE:-false}" == true ]] || return 0
  local repo_root="$1" rc=0
  # Preserve complete-suite coverage before isolated test-phase agents can reset it.
  makevn_scoped_coverage_finish "${repo_root}" || return $?
  if makevn_capture_test_impact "$@"; then return 0; else rc=$?; fi
  rm -f "$(makevn_scoped_coverage_state "${repo_root}")/run.json"
  return "${rc}"
}

makevn_validate_prepared_impact() {
  [[ "${MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN}" != *$'\t*'* && -n "${MAKEVN_VERIFY_CHANGES_SRC_FILES:-}" ]] || return 0
  local java_home prepared
  java_home="$(makevn_effective_java_home "$1" code "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}")" || return $?
  prepared="$(printf '%s\n%s\n' "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" "${MAKEVN_VERIFY_CHANGES_TEST_FILES:-}" | MAKEVN_TEST_IMPACT_JAVA="${java_home}/bin/java" python3 "${SCRIPT_DIR}/common/changes_scope.py" "$1" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${MAKEVN_VERIFY_CHANGES_PARENT_SPEC}" --focused-plan)" || return $?
  [[ "${prepared}" == "${MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN}" ]] || makevn_die "Prepared static impact changed; run verify-changes-preview again."
}

cmd_test_impact() (
  local repo_root="$1" mode="$2"
  shift 2
  local MAKEVN_TEST_IMPACT_ISOLATED=false
  local isolated_args=()
  if [[ "${1:-}" == --isolated ]]; then
    [[ "${mode}" == init ]] || makevn_die "--isolated is only supported by test-impact-init"
    MAKEVN_TEST_IMPACT_ISOLATED=true
    isolated_args=(--isolated)
    shift
  fi
  [[ $# -eq 0 ]] || makevn_die "test-impact-${mode} does not accept additional arguments"
  if [[ "${mode}" == init && "${MAKEVN_TEST_IMPACT_LOCK_HELD:-}" != true ]]; then
    python3 "${SCRIPT_DIR}/common/test_impact_lock.py" "${repo_root}" "${SCRIPT_DIR}/cli.sh" test-impact-init ${isolated_args[@]+"${isolated_args[@]}"}
    return $?
  fi
  makevn_run_test_impact "${repo_root}" "${mode}"
)

makevn_test_impact_status() {
  local repo_root="$1" base java_home
  makevn_load_profile "${repo_root}"
  base="$(makevn_detect_maven_base_path "${repo_root}")" || return $?
  java_home="$(makevn_effective_java_home "${repo_root}" code "${base}")" || {
    printf 'Cannot inspect test impact: no unambiguous compatible JDK is configured. Run makevn doctor and resolve Java selection before retrying.\n' >&2
    return 1
  }
  if [[ "${MAKEVN_TEST_IMPACT_ISOLATED:-false}" == true ]]; then
    python3 "${SCRIPT_DIR}/common/test_impact.py" status "${repo_root}" "${base}" "${java_home}/bin/java"
    return $?
  fi
  python3 "${SCRIPT_DIR}/common/progressive_impact.py" "${2:-preview}" "${repo_root}" "${base}" "${java_home}/bin/java"
}

makevn_run_test_impact() {
  local rc=0
  makevn_test_impact_status "$1" "$2" || rc=$?
  if [[ "${MAKEVN_TEST_IMPACT_ISOLATED:-false}:${rc}" == true:2 ]]; then
    local MAKEVN_TEST_IMPACT_INITIALIZE=true
    cmd_verify_changes "$1" --record-test-impact
  else
    return "${rc}"
  fi
}

makevn_test_impact_scope() {
  MAKEVN_VERIFY_CHANGES_PARENT_SPEC=HEAD
  MAKEVN_VERIFY_CHANGES_SRC_FILES=''
  MAKEVN_VERIFY_CHANGES_TEST_FILES=''
  MAKEVN_VERIFY_CHANGES_POM_FILES=''
  MAKEVN_VERIFY_CHANGES_TEST_LIST=''
  MAKEVN_VERIFY_CHANGES_CLASSES=''
  MAKEVN_VERIFY_CHANGES_MODULE_SELECTION=.
  MAKEVN_VERIFY_CHANGES_MODULES=.
  MAKEVN_VERIFY_CHANGES_SCOPE_REQUIRED=false
  MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN=$'.\t*'
}

makevn_retire_test_impact() {
  local java_home
  java_home="$(makevn_effective_java_home "$1" code "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}")" || return $?
  python3 "${SCRIPT_DIR}/common/test_impact.py" retire "$1" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${java_home}/bin/java"
}

makevn_dispatch_verify_changes() {
  local repo_root="$1"
  shift
  makevn_changes_mode "$@"
  if [[ "${MAKEVN_TEST_IMPACT_CAPTURE}" == true && "${MAKEVN_TEST_IMPACT_LOCK_HELD:-}" != true ]]; then
    python3 "${SCRIPT_DIR}/common/test_impact_lock.py" "${repo_root}" "${SCRIPT_DIR}/cli.sh" verify-changes "$@"
  else
    cmd_verify_changes "${repo_root}" "$@"
  fi
}
