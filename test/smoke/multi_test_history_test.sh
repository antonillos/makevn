#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/libexec/makevn/common.sh"
source "${ROOT}/libexec/makevn/commands/maven.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
export MAKEVN_BACKEND_PHASE_DIR="${tmp}/phases"
export MAKEVN_BACKEND_METADATA_OUT="${tmp}/active"
export MAKEVN_BACKEND_DETAIL_OUT="${tmp}/detail"
mkdir "${MAKEVN_BACKEND_PHASE_DIR}"
makevn_run_selected_test() {
  local name="$2"
  printf '%s\n' "${name}" >> "${tmp}/executed"
  printf 'command=test\nrepo=%s\ncwd=%s\nlog_path=/log/%s\nrelative_log_path=%s.log\ncommand_display=makevn test\ntitle=test %s\n' "$1" "$1" "${name}" "${name}" "${name}" > "${MAKEVN_BACKEND_METADATA_OUT}"
  printf 'Details %s\n' "${name}" > "${MAKEVN_BACKEND_DETAIL_OUT}"
  [[ "${name}" != Fail ]]
}
if cmd_test "${tmp}" --name First,Fail,Last > "${tmp}/out"; then exit 1; fi
[[ "$(cat "${tmp}/executed")" == $'First\nFail\nLast' ]]
for i in 1 2 3; do [[ -f "${MAKEVN_BACKEND_PHASE_DIR}/${i}" ]]; done
grep -q 'title=test First' "${MAKEVN_BACKEND_PHASE_DIR}/1"
grep -q 'relative_log_path=First.log' "${MAKEVN_BACKEND_PHASE_DIR}/1"
grep -q 'exit_code=1' "${MAKEVN_BACKEND_PHASE_DIR}/2"
grep -q 'exit_code=0' "${MAKEVN_BACKEND_PHASE_DIR}/3"
grep -q 'Details First' "${MAKEVN_BACKEND_PHASE_DIR}/1.detail"
grep -q '3 executed, 2 passed, 1 failed' "${MAKEVN_BACKEND_PHASE_DIR}/4"
rm -f "${tmp}/executed"
cmd_test "${tmp}" --name First,Last > "${tmp}/success"
grep -q '2 executed, 2 passed, 0 failed' "${tmp}/success"
printf 'Multi-test history regression passed\n'
