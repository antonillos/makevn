#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="${ROOT}/libexec/makevn"
source "${SCRIPT_DIR}/commands/test_impact.sh"
source "${SCRIPT_DIR}/common/ui.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
makevn_die() { printf '%s\n' "$*" >&2; exit 1; }
makevn_load_profile() { :; }
makevn_detect_maven_base_path() { printf '%s\n' "$tmp"; }
makevn_effective_java_home() { printf '/fixture/java\n'; }
cmd_verify_changes() {
  [[ "${MAKEVN_TEST_IMPACT_INITIALIZE}" == true && "$2" == --record-test-impact ]]
  touch "${tmp}/verified"
}
python3() {
  if [[ "$1" == */test_impact_lock.py ]]; then
    [[ "$4" == test-impact-init || "$4" == verify-changes ]]
    touch "${tmp}/locked"
    return 0
  fi
  if [[ "$1" == */progressive_impact.py ]]; then
    [[ "$2" == preview || "$2" == init ]]
    printf '%s\n' "$2" > "${tmp}/static-mode"
    printf '%s\n' "$@" > "${tmp}/static-args"
    if [[ " $* " == *' --graph '* ]]; then printf 'Graph summary\nFocus details\n'; fi
    return "${STATIC_STATUS:-0}"
  fi
  [[ "$2" == status || "$2" == retire ]]
  return "${STATUS:-2}"
}
cmd_test_impact "${tmp}" preview
[[ ! -e "${tmp}/verified" && ! -e "${tmp}/locked" ]]
cmd_test_impact "${tmp}" preview --graph --focus example.Foo
[[ "$(tail -3 "${tmp}/static-args")" == $'--graph\n--focus\nexample.Foo' ]]
MAKEVN_TEST_IMPACT_GRAPH=true
MAKEVN_BACKEND_DETAIL_OUT="${tmp}/details"
: > "${MAKEVN_BACKEND_DETAIL_OUT}"
makevn_test_impact_status "${tmp}" preview
[[ "$(cat "${MAKEVN_BACKEND_DETAIL_OUT}")" == $'Graph summary\nFocus details' ]]
unset MAKEVN_TEST_IMPACT_GRAPH MAKEVN_BACKEND_DETAIL_OUT
if cmd_test_impact "${tmp}" preview --focus example.Foo; then exit 1; fi
cmd_test_impact "${tmp}" init
[[ -e "${tmp}/locked" && ! -e "${tmp}/verified" ]]
MAKEVN_TEST_IMPACT_LOCK_HELD=true
STATUS=0
cmd_test_impact "${tmp}" init
[[ ! -e "${tmp}/verified" ]]
STATUS=2
cmd_test_impact "${tmp}" init
[[ ! -e "${tmp}/verified" && "$(cat "${tmp}/static-mode")" == init ]]
cmd_test_impact "${tmp}" init --isolated
[[ -e "${tmp}/verified" ]]
STATIC_STATUS=1
if cmd_test_impact "${tmp}" init; then exit 1; fi
if cmd_test_impact "${tmp}" preview extra; then exit 1; fi
STATUS=0
STATIC_STATUS=0
MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH="${tmp}"
makevn_retire_test_impact "${tmp}"
makevn_test_impact_scope
[[ "${MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN}" == $'.\t*' && "${MAKEVN_VERIFY_CHANGES_MODULE_SELECTION}" == . ]]
[[ -z "${MAKEVN_VERIFY_CHANGES_SRC_FILES}${MAKEVN_VERIFY_CHANGES_TEST_FILES}" ]]
source "${SCRIPT_DIR}/commands/changes.sh"
cmd_verify_changes() { printf '%s\n' "$@" > "${tmp}/forwarded"; }
makevn_dispatch_verify_changes "${tmp}" --record-test-impact -- -Dexample=value
[[ "$(tail -1 "${tmp}/forwarded")" == -Dexample=value ]]
unset MAKEVN_TEST_IMPACT_LOCK_HELD
rm "${tmp}/locked"
makevn_dispatch_verify_changes "${tmp}" --record-test-impact
[[ -e "${tmp}/locked" ]]
git -C "${tmp}" init -q
git -C "${tmp}" -c user.name=Test -c user.email=test@example.test commit --allow-empty --no-gpg-sign -qm fixture
makevn_maven_executable() { printf '/fixture/maven\n'; }
makevn_effective_local_containers() { printf '\n'; }
MAKEVN_TEST_IMPACT_INITIALIZE=true
makevn_collect_verify_changes_scope "${tmp}"
[[ "${MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN}" == $'.\t*' ]]
[[ -z "${MAKEVN_VERIFY_CHANGES_SRC_FILES}${MAKEVN_VERIFY_CHANGES_TEST_FILES}" ]]

printf 'Test impact initialization command contract passed\n'
