#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/commands/karate.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
export MAKEVN_BACKEND_PHASE_DIR="${tmp}" MAKEVN_BACKEND_METADATA_OUT="${tmp}/metadata" MAKEVN_BACKEND_DETAIL_OUT="${tmp}/detail"
cmd_phase() {
  printf 'title=phase\n' > "${MAKEVN_BACKEND_METADATA_OUT}"
  printf '%s details\n' "$1" > "${MAKEVN_BACKEND_DETAIL_OUT}"
  return "$2"
}
makevn_run_karate_phase 1 cmd_phase docker 0
makevn_run_karate_phase 3 cmd_phase app 0
set +e
makevn_run_karate_phase 5 cmd_phase tests 42
rc=$?
set -e
[[ ${rc} == 42 ]]
grep -q 'exit_code=0' "${tmp}/1"
grep -q 'exit_code=42' "${tmp}/5"
grep -q 'duration_seconds=' "${tmp}/3"
[[ $(cat "${tmp}/5.detail") == 'tests details' ]]
! grep -q app "${tmp}/5.detail"
cmd_package() { return 17; }
set +e
makevn_run_karate_phase 2 cmd_package /repo
rc=$?
set -e
[[ ${rc} == 17 ]]
grep -q 'title=package' "${tmp}/2"
grep -q '^log_path=$' "${tmp}/2"
printf 'Karate phase record tests passed\n'
