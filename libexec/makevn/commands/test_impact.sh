#!/usr/bin/env bash

makevn_capture_impact_class() (
  local repo_root="$1" name="$2" traces
  shift 2
  traces="$(mktemp -d "$(makevn_state_dir "${repo_root}")/test-impact/traces.XXXXXX")"
  trap 'rm -rf "${traces}"' EXIT
  [[ "${1:-}" != env ]] || shift
  makevn_verify_focused_owner "${repo_root}" . "${name}" env "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS:-} \"-Xlog:class+load=info:file=${traces}/%p.log\"" "$@" || return $?
  python3 "${SCRIPT_DIR}/common/test_impact.py" record "${repo_root}" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${name}" "${traces}"
)

makevn_capture_test_impact() {
  [[ "${MAKEVN_TEST_IMPACT_CAPTURE:-false}" == true ]] || return 0
  local repo_root="$1" stamp="$2" java_home tests name
  shift 2
  java_home="$(makevn_effective_java_home "${repo_root}" code "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}")" || return $?
  tests="$(python3 "${SCRIPT_DIR}/common/test_impact.py" begin "${repo_root}" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${java_home}/bin/java" "${stamp}")" || return $?
  makevn_print_item "test impact capture" "isolating every test class; one verification per class; future compatible focused runs reuse this evidence"
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    MAKEVN_FOCUSED_PHASE_INDEX=$((MAKEVN_FOCUSED_PHASE_INDEX + 1))
    makevn_capture_impact_class "${repo_root}" "${name}" "$@" || return $?
  done <<< "${tests}"
  python3 "${SCRIPT_DIR}/common/test_impact.py" finish "${repo_root}" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${java_home}/bin/java"
}

makevn_validate_prepared_impact() {
  [[ "${MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN}" != *$'\t*'* && -n "${MAKEVN_VERIFY_CHANGES_SRC_FILES:-}" ]] || return 0
  printf '%s\n%s\n' "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" "${MAKEVN_VERIFY_CHANGES_TEST_FILES:-}" | python3 "${SCRIPT_DIR}/common/test_impact.py" validate-prepared "$1" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}"
}
