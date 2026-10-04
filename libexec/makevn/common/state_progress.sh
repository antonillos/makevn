#!/usr/bin/env bash

# Reuse the metadata/completion record contract used by Karate's dashboard.
makevn_complete_state_phase() {
  local rc="${1:-0}"
  [[ -n "${MAKEVN_STATE_PHASE_INDEX:-}" ]] || return 0
  local record="${MAKEVN_BACKEND_PHASE_DIR}/${MAKEVN_STATE_PHASE_INDEX}"
  local pending="${record}.pending"
  cp "${MAKEVN_FRONTEND_STATE_METADATA_OUT}" "${pending}"
  printf '\ntitle=%s\nduration_seconds=%s\nexit_code=%s\n' "${MAKEVN_STATE_PHASE_TITLE}" "$((SECONDS - MAKEVN_STATE_PHASE_STARTED))" "${rc}" >> "${pending}"
  [[ -z "${MAKEVN_BACKEND_DETAIL_OUT:-}" ]] || tail -n +2 "${MAKEVN_BACKEND_DETAIL_OUT}" > "${record}.detail"
  mv "${pending}" "${record}"
}

makevn_start_state_phase() {
  local message="$1"
  [[ -n "${MAKEVN_FRONTEND_STATE_METADATA_OUT:-}" && -n "${MAKEVN_BACKEND_PHASE_DIR:-}" ]] || return 0
  makevn_complete_state_phase 0
  MAKEVN_STATE_PHASE_INDEX="$((${MAKEVN_STATE_PHASE_INDEX:-0} + 1))"
  MAKEVN_STATE_PHASE_STARTED="${SECONDS}"
  MAKEVN_STATE_PHASE_TITLE="${message}"
  [[ -z "${MAKEVN_BACKEND_DETAIL_OUT:-}" ]] || printf '%s\n' "${message}" > "${MAKEVN_BACKEND_DETAIL_OUT}"
  makevn_write_backend_metadata "${MAKEVN_FRONTEND_STATE_METADATA_OUT}" doctor "${repo_root}" "${repo_root}" "" "" "makevn doctor" "" doctor
  trap 'makevn_complete_state_phase "$?"' EXIT
}
