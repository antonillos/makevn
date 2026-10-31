#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/fake-java/bin"
makevn_effective_java_home() { printf '%s/fake-java\n' "${TMP}"; }
makevn_test_process_preflight() { return 0; }
makevn_check_maven_command() { return 0; }
export MAKEVN_BACKEND_DETAIL_OUT="${TMP}/details"
for frontend in shell rust; do
  export MAKEVN_FRONTEND="${frontend}" MAKEVN_FRONTEND_OWNS_LOADER=1
  if MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${TMP}" code "${TMP}" test verify test \
      bash -c 'printf "client version 1.32 is too old. Minimum supported API version is 1.40\n"; for ((i=0;i<50;i++)); do printf "[ERROR] context failed\n"; done; exit 7' \
      > "${TMP}/output" 2>&1; then
    exit 1
  else
    [[ $? -eq 7 ]]
  fi
  for file in output details .makevn/logs/test.log; do
    grep -q 'Docker API incompatibility: the project client uses API 1.32' "${TMP}/${file}"
    grep -q 'reachable engine requires at least API 1.40' "${TMP}/${file}"
  done
done
: > "${TMP}/details"
MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${TMP}" code "${TMP}" success verify test \
  printf 'client version 1.32 is too old. Minimum supported API version is 1.40\n' > "${TMP}/output"
[[ ! -s "${TMP}/details" ]]
! grep -q 'Docker API incompatibility' "${TMP}/.makevn/logs/success.log"
unset MAKEVN_BACKEND_DETAIL_OUT MAKEVN_FRONTEND MAKEVN_FRONTEND_OWNS_LOADER
printf 'client version 1.32 is too old. Minimum supported API version is 1.40\n' > "${TMP}/direct.log"
makevn_report_docker_api_failure "${TMP}/direct.log" 2> "${TMP}/stderr"
grep -q 'Docker API incompatibility' "${TMP}/stderr"
makevn_report_docker_api_failure "${TMP}/missing.log" 2> "${TMP}/stderr"
[[ ! -s "${TMP}/stderr" ]]
printf 'Docker API failure diagnostics passed\n'
