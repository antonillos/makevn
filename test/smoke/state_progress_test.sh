#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common.sh"
repo_root="$(mktemp -d)"
trap 'rm -rf "${repo_root}"' EXIT
# Agent execution must not create phase state.
makevn_start_state_phase "Agent probe"
[[ -z "${MAKEVN_STATE_PHASE_INDEX:-}" ]]
export MAKEVN_FRONTEND_STATE_METADATA_OUT="${repo_root}/metadata"
export MAKEVN_BACKEND_PHASE_DIR="${repo_root}/phases"
export MAKEVN_BACKEND_DETAIL_OUT="${repo_root}/details"
mkdir -p "${MAKEVN_BACKEND_PHASE_DIR}"
makevn_start_state_phase "First inspection"
makevn_print_item "First result" "retained"
makevn_start_state_phase "Second inspection"
grep -Fqx 'title=First inspection' "${MAKEVN_BACKEND_PHASE_DIR}/1"
grep -Fqx 'exit_code=0' "${MAKEVN_BACKEND_PHASE_DIR}/1"
grep -Fqx 'First result: retained' "${MAKEVN_BACKEND_PHASE_DIR}/1.detail"
! grep -Fqx 'First inspection' "${MAKEVN_BACKEND_PHASE_DIR}/1.detail"
makevn_print_item "Second result" "retained"
makevn_complete_state_phase 0
if (makevn_start_state_phase "Failed inspection"; false); then
  printf 'Expected failed inspection\n' >&2
  exit 1
fi
grep -Fqx 'title=Failed inspection' "${MAKEVN_BACKEND_PHASE_DIR}/3"
grep -Fqx 'exit_code=1' "${MAKEVN_BACKEND_PHASE_DIR}/3"
[[ ! -e "${MAKEVN_BACKEND_PHASE_DIR}/4" ]]
trap 'rm -rf "${repo_root}"' EXIT
printf 'State progress tests passed\n'
