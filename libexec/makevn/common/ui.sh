#!/usr/bin/env bash
set -euo pipefail

makevn_use_color() {
  [[ -t 1 ]] || [[ -t 2 ]] || return 1
  [[ "${TERM:-}" != "dumb" ]]
  [[ -z "${NO_COLOR:-}" ]]
}

makevn_style() {
  local code="$1"
  shift
  if makevn_use_color; then
    printf '\033[%sm%s\033[0m' "${code}" "$*"
  else
    printf '%s' "$*"
  fi
}

makevn_dim() {
  makevn_style "90" "$*"
}

makevn_accent() {
  makevn_style "36" "$*"
}

makevn_warn() {
  makevn_style "33" "$*"
}

makevn_print_header() {
  local title="$1"
  printf '%s %s\n' "$(makevn_dim '::')" "$(makevn_accent "${title}")"
}

makevn_print_item() {
  local label="$1"
  local value="$2"
  if [[ -n "${MAKEVN_BACKEND_DETAIL_OUT:-}" ]]; then
    printf '%s: %s\n' "${label}" "${value}" >> "${MAKEVN_BACKEND_DETAIL_OUT}"
  else
    printf '%s %s%s\n' "$(makevn_dim '│')" "${label}:" " ${value}"
  fi
}

makevn_print_detail_line() {
  local line="$1"
  if [[ -n "${MAKEVN_BACKEND_DETAIL_OUT:-}" ]]; then
    printf '%s\n' "${line}" >> "${MAKEVN_BACKEND_DETAIL_OUT}"
  else
    printf '%s\n' "${line}"
  fi
}

makevn_print_command_header() {
  local title="$1"
  local pid="${2:-}"
  local log_path="${3:-}"
  local line=""
  local prefix="::"

  if [[ "${MAKEVN_COMPACT_OUTPUT:-}" == "1" ]]; then
    prefix="[..]"
  fi

  line="$(makevn_accent "makevn ${title}")"
  if [[ -n "${pid}" ]]; then
    line+=" $(makevn_dim '|') $(makevn_dim "pid: ${pid}")"
  fi
  if [[ -n "${log_path}" ]]; then
    line+=" $(makevn_dim '|') $(makevn_dim "log: ${log_path}")"
  fi

  printf '%s %s\n' "$(makevn_dim "${prefix}")" "${line}"
}
