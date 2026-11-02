#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="${ROOT}/libexec/makevn"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/commands/focused_changes.sh"
makevn_changes_mode
makevn_focused_coverage_gate_flags
[[ "${MAKEVN_DEFER_GLOBAL_COVERAGE}" == false && ${#MAKEVN_FOCUSED_COVERAGE_GATE_FLAGS[@]} == 0 ]]
makevn_changes_mode --defer-global-coverage --focused
[[ "${MAKEVN_VERIFY_CHANGES_MODE_ARGS}" == 2 ]]
makevn_focused_coverage_gate_flags
[[ "${MAKEVN_FOCUSED_COVERAGE_GATE_FLAGS[*]}" == '-Djacoco.haltOnFailure=false -Dcommons.jacoco.haltOnFailure=false' ]]
output="$(makevn_print_deferred_global_coverage)"
[[ "${output}" == *'violations remain visible'* && "${output}" == *'full verify/CI coverage remains required'* ]]
if (makevn_changes_mode --defer-global-coverage --exhaustive) >/dev/null 2>&1; then exit 1; fi
if (makevn_changes_mode --record-test-impact --defer-global-coverage) >/dev/null 2>&1; then exit 1; fi
makevn_changes_mode --record-test-impact
makevn_focused_coverage_gate_flags
[[ ${#MAKEVN_FOCUSED_COVERAGE_GATE_FLAGS[@]} == 0 ]]
makevn_changes_mode
[[ -z "$(makevn_print_deferred_global_coverage)" ]]
printf 'Explicit focused coverage deferral contract passed\n'
