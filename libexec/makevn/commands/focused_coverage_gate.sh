#!/usr/bin/env bash

makevn_validate_deferred_global_coverage() {
  [[ "${MAKEVN_DEFER_GLOBAL_COVERAGE:-false}" == true ]] || return 0
  [[ "${MAKEVN_VERIFY_CHANGES_MODE}:${MAKEVN_TEST_IMPACT_CAPTURE}" == focused:false ]] || makevn_die "--defer-global-coverage requires focused verification without --record-test-impact"
}

makevn_focused_coverage_gate_flags() {
  MAKEVN_FOCUSED_COVERAGE_GATE_FLAGS=()
  [[ "${MAKEVN_DEFER_GLOBAL_COVERAGE:-false}" == true ]] || return 0
  MAKEVN_FOCUSED_COVERAGE_GATE_FLAGS=(-Djacoco.haltOnFailure=false -Dcommons.jacoco.haltOnFailure=false)
}

makevn_print_deferred_global_coverage() {
  [[ "${MAKEVN_DEFER_GLOBAL_COVERAGE:-false}" == true ]] || return 0
  makevn_print_item "global coverage" "JaCoCo failure deferred explicitly via standard/Apache Commons properties; violations remain visible; other gates still enforced"
  makevn_print_item "changed-code gates" "run coverage-changes and crap-changes after success; full verify/CI coverage remains required"
}
