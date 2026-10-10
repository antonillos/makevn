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
MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN=$'boot\texample.OwnersIT\nclient\t*'
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
makevn_run_focused_changes "${tmp}"
[[ "$(wc -l < "${tmp}/commands" | tr -d ' ')" == 3 ]]
sed -n '1p' "${tmp}/commands" | grep -Fq -- '-pl boot,client -am install -DskipTests=true -DskipUTs=true -DskipITs=true'
sed -n '2p' "${tmp}/commands" | grep -Fq -- '-pl boot verify -DskipTests=false -DskipUTs=false -DskipITs=false -Dtest=!%regex[.*] -Dit.test=example.OwnersIT'
sed -n '3p' "${tmp}/commands" | grep -q -- '-pl client verify -DskipTests=false -DskipUTs=false -DskipITs=false$'
! tail -n 2 "${tmp}/commands" | grep -q -- '-am'
[[ -f "${MAKEVN_BACKEND_PHASE_DIR}/1" && -f "${MAKEVN_BACKEND_PHASE_DIR}/2" && -f "${MAKEVN_BACKEND_PHASE_DIR}/3" ]]
: > "${tmp}/commands"
FAIL_PREPARE=1
if makevn_run_focused_changes "${tmp}"; then exit 1; fi
[[ "$(wc -l < "${tmp}/commands" | tr -d ' ')" == 1 ]]
if (makevn_validate_focused_flags -am) >/dev/null 2>&1; then exit 1; fi
if (makevn_validate_focused_flags -Dtest=OtherTest) >/dev/null 2>&1; then exit 1; fi
makevn_changes_mode --focused
[[ "${MAKEVN_VERIFY_CHANGES_MODE}" == focused && "${MAKEVN_VERIFY_CHANGES_MODE_ARGS}" == 1 ]]
makevn_changes_mode --exhaustive
[[ "${MAKEVN_VERIFY_CHANGES_MODE}" == exhaustive && "${MAKEVN_VERIFY_CHANGES_MODE_ARGS}" == 1 ]]
makevn_changes_mode
[[ "${MAKEVN_VERIFY_CHANGES_MODE}" == exhaustive ]]
printf 'Focused changes phases regression passed\n'
