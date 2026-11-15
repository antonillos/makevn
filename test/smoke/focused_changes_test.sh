#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="${ROOT}/libexec/makevn"
source "${ROOT}/libexec/makevn/common.sh"
source "${ROOT}/libexec/makevn/commands/maven.sh"
source "${ROOT}/libexec/makevn/commands/focused_changes.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH="${tmp}"
MAKEVN_VERIFY_CHANGES_MODULE_SELECTION=boot,client
MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN=$'boot\t*\nclient\t*'
plan_output="$(makevn_print_focused_changes_plan)"
[[ "${plan_output}" == *'static affected modules and their upstream dependencies; complete suites'* ]]
[[ "${plan_output}" == *'complete suites in selected modules and dependencies together with -am'*  ]]
verify_args=(mvn)
cli_flags=(-nsu)
prop_flags=(-Djacoco.skip=false)
export MAKEVN_BACKEND_PHASE_DIR="${tmp}/phases"
export MAKEVN_BACKEND_METADATA_OUT="${tmp}/active"
export MAKEVN_BACKEND_DETAIL_OUT="${tmp}/detail"
mkdir "${MAKEVN_BACKEND_PHASE_DIR}"
mkdir -p "${tmp}/.makevn"
makevn_run_logged_in_context() {
  printf '%s\n' "$*" >> "${tmp}/commands"
  if [[ "$*" == *'-pl boot verify'* ]]; then
    mkdir -p "${tmp}/boot/target/failsafe-reports"
    printf '<testsuite><testcase classname="example.OwnersIT" name="works"/></testsuite>' > "${tmp}/boot/target/failsafe-reports/TEST-example.OwnersIT.xml"
  fi
  [[ "${FAIL_PREPARE:-0}" != 1 ]]
}
makevn_scoped_coverage_checkpoint() {
  [[ "$(wc -l < "${tmp}/commands" | tr -d ' ')" == 1 ]]
  [[ "${FAIL_CHECKPOINT:-0}" != 1 ]]
}
makevn_run_focused_changes "${tmp}"
[[ "$(wc -l < "${tmp}/commands" | tr -d ' ')" == 2 ]]
sed -n '1p' "${tmp}/commands" | grep -Fq -- '-pl boot,client -am package -DskipTests=true -DskipUTs=true -DskipITs=true'
sed -n '2p' "${tmp}/commands" | grep -Fq -- '-pl boot,client -am verify -DskipTests=false -DskipUTs=false -DskipITs=false'
! grep -q -- '-Dtest=' "${tmp}/commands"
! grep -q -- ' install ' "${tmp}/commands"
grep -q 'command=verify-changes' "${MAKEVN_BACKEND_PHASE_DIR}/1"
grep -q 'title=prepare dependencies (no tests)' "${MAKEVN_BACKEND_PHASE_DIR}/1"
[[ -f "${MAKEVN_BACKEND_PHASE_DIR}/1" && -f "${MAKEVN_BACKEND_PHASE_DIR}/2" ]]
: > "${tmp}/commands"
FAIL_PREPARE=1
if makevn_run_focused_changes "${tmp}"; then exit 1; fi
[[ "$(wc -l < "${tmp}/commands" | tr -d ' ')" == 1 ]]
FAIL_PREPARE=0
FAIL_CHECKPOINT=1
: > "${tmp}/commands"
if makevn_run_focused_changes "${tmp}"; then exit 1; fi
[[ "$(wc -l < "${tmp}/commands" | tr -d ' ')" == 1 ]]
if (makevn_validate_focused_flags -am) >/dev/null 2>&1; then exit 1; fi
if (makevn_validate_focused_flags -Dtest=OtherTest) >/dev/null 2>&1; then exit 1; fi
makevn_changes_mode --focused
[[ "${MAKEVN_VERIFY_CHANGES_MODE}" == focused && "${MAKEVN_VERIFY_CHANGES_MODE_ARGS}" == 1 ]]
makevn_changes_mode --exhaustive
[[ "${MAKEVN_VERIFY_CHANGES_MODE}" == exhaustive && "${MAKEVN_VERIFY_CHANGES_MODE_ARGS}" == 1 ]]
makevn_changes_mode
[[ "${MAKEVN_VERIFY_CHANGES_MODE}" == focused ]]
makevn_changes_mode --record-test-impact --focused
[[ "${MAKEVN_TEST_IMPACT_CAPTURE}" == true && "${MAKEVN_VERIFY_CHANGES_MODE_ARGS}" == 2 ]]
if (makevn_changes_mode --record-test-impact --exhaustive) >/dev/null 2>&1; then exit 1; fi
FAIL_CHECKPOINT=0
makevn_changes_mode --defer-global-coverage
: > "${tmp}/commands"
makevn_run_focused_changes "${tmp}"
[[ "$(grep -c -- '-Djacoco.haltOnFailure=false -Dcommons.jacoco.haltOnFailure=false' "${tmp}/commands")" == 2 ]]
[[ "$(grep -c -- '-Djacoco.skip=false' "${tmp}/commands")" == 2 ]]
! grep -q -- '-Djacoco.skip=true' "${tmp}/commands"
FAIL_PREPARE=1
: > "${tmp}/commands"
if makevn_run_focused_changes "${tmp}"; then exit 1; fi
[[ "$(wc -l < "${tmp}/commands" | tr -d ' ')" == 1 ]]
printf 'Focused changes phases regression passed\n'
