#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="${ROOT}/libexec/makevn"
source "${SCRIPT_DIR}/commands/focused_changes.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/.makevn/coverage" "${tmp}/.makevn/test-impact"
makevn_state_dir() { printf '%s/.makevn\n' "$1"; }
makevn_scoped_coverage_state() { printf '%s/.makevn/coverage\n' "$1"; }
makevn_scoped_coverage_finish() {
  cp "${tmp}/data.exec" "${tmp}/.makevn/coverage/full.exec"
  touch "${tmp}/.makevn/coverage/run.json"
}
makevn_capture_test_impact() {
  printf partial > "${tmp}/data.exec"
  return "${CAPTURE_RC:-0}"
}
MAKEVN_TEST_IMPACT_CAPTURE=true
printf complete > "${tmp}/data.exec"
makevn_finish_test_impact_capture "${tmp}" stamp
[[ "$(cat "${tmp}/.makevn/coverage/full.exec")" == complete ]]
[[ -f "${tmp}/.makevn/coverage/run.json" ]]
printf complete > "${tmp}/data.exec"
CAPTURE_RC=7
if makevn_finish_test_impact_capture "${tmp}" stamp; then exit 1; else [[ "$?" == 7 ]]; fi
[[ ! -f "${tmp}/.makevn/coverage/run.json" ]]
# Unit replays avoid package/verify, while ordinary focused verification retains verify.
MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH="${tmp}"
makevn_focused_test_selection() { MAKEVN_FOCUSED_SELECTION=(); }
makevn_focused_changes_phase() { printf '%s\n' "$@" > "${tmp}/arguments"; }
MAKEVN_TEST_IMPACT_REPLAY_GOAL=test
makevn_verify_focused_owner "${tmp}" . example.OwnerTest fake-maven
[[ "$(sed -n '6p' "${tmp}/arguments")" == test ]]
unset MAKEVN_TEST_IMPACT_REPLAY_GOAL
makevn_verify_focused_owner "${tmp}" . example.OwnerIT fake-maven
[[ "$(sed -n '6p' "${tmp}/arguments")" == verify ]]
printf 'Isolated replay lifecycle and full-suite coverage preservation passed\n'
# An explicit capture chooses test for UT and preserves verify for IT.
python3() { [[ "$2" == record ]]; }
makevn_capture_impact_class "${tmp}" example.OwnerTest fake-maven
grep -qx test "${tmp}/arguments"
makevn_capture_impact_class "${tmp}" example.OwnerIT fake-maven
grep -qx verify "${tmp}/arguments"
# Recheck static scope after dependency preparation; refuse a changed selection.
MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN=$'.\texample.OwnerTest'
MAKEVN_VERIFY_CHANGES_SRC_FILES=src/main/java/example/Owner.java
MAKEVN_VERIFY_CHANGES_PARENT_SPEC=HEAD
makevn_effective_java_home() { printf '/fixture/jdk\n'; }
makevn_die() { printf '%s\n' "$*" >&2; return 1; }
python3() { printf '%s\n' "${PREPARED_PLAN}"; }
PREPARED_PLAN="${MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN}"
makevn_validate_prepared_impact "${tmp}"
PREPARED_PLAN=$'.\t*'
if makevn_validate_prepared_impact "${tmp}"; then exit 1; fi
# The prepared plan must retain every selected consumer owner.
PREPARED_PLAN=$'app\texample.ApplicationTest\ncore\texample.OwnerTest\nservice\t*'
makevn_collect_focused_plan src/main/java/Owner.java "${tmp}" HEAD preview
[[ "${MAKEVN_VERIFY_CHANGES_MODULE_SELECTION}" == app,core,service ]]
makevn_validate_prepared_impact "${tmp}"
PREPARED_PLAN=$'app\t*\ncore\t*\nservice\t*'
if makevn_validate_prepared_impact "${tmp}"; then exit 1; fi
