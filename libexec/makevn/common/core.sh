#!/usr/bin/env bash
set -euo pipefail

makevn_die() {
  if [[ -n "${MAKEVN_BACKEND_METADATA_OUT:-}" && -n "${MAKEVN_BACKEND_REPO_ROOT:-}" && -n "${MAKEVN_BACKEND_COMMAND:-}" ]] \
    && declare -F makevn_write_quick_backend_log >/dev/null 2>&1; then
    makevn_write_quick_backend_log \
      "${MAKEVN_BACKEND_REPO_ROOT}" \
      "${MAKEVN_BACKEND_COMMAND}" \
      "${MAKEVN_BACKEND_COMMAND}" \
      "${MAKEVN_BACKEND_COMMAND}" \
      "${MAKEVN_BACKEND_COMMAND_DISPLAY:-makevn ${MAKEVN_BACKEND_COMMAND}}" \
      "Error: $*"
  fi
  if makevn_frontend_owns_loader 2>/dev/null; then
    exit 1
  fi
  printf '%s\n' "$(makevn_warn "Error: $*")" >&2
  exit 1
}

makevn_now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

makevn_resolve_repo_root() {
  local candidate="${1:-$PWD}"
  local resolved=""
  if [[ ! -d "${candidate}" ]]; then
    makevn_die "Repository path does not exist: ${candidate}"
  fi
  resolved="$(CDPATH= cd -- "${candidate}" && pwd)"
  makevn_find_git_root_from_resolved_path "${resolved}" || printf '%s\n' "${resolved}"
}

makevn_find_git_root_from_resolved_path() {
  local current="$1"
  while [[ "${current}" != "/" ]]; do
    if [[ -d "${current}/.git" || -f "${current}/.git" ]]; then
      printf '%s\n' "${current}"
      return 0
    fi
    current="$(dirname "${current}")"
  done
  return 1
}

makevn_require_repo_path_is_git_root() {
  local candidate="$1"
  local command="$2"
  local resolved=""
  local git_root=""

  if [[ ! -d "${candidate}" ]]; then
    makevn_die "Repository path does not exist: ${candidate}"
  fi

  resolved="$(CDPATH= cd -- "${candidate}" && pwd)"
  git_root="$(makevn_find_git_root_from_resolved_path "${resolved}" || true)"
  if [[ -n "${git_root}" && "${resolved}" != "${git_root}" ]]; then
    makevn_die "makevn ${command} must be run from the Git repository root: ${git_root} (received: ${resolved})"
  fi
}

makevn_state_dir() {
  printf '%s/.makevn\n' "$1"
}

makevn_manifest_path() {
  printf '%s/manifest\n' "$(makevn_state_dir "$1")"
}

makevn_state_json_path() {
  printf '%s/state.json\n' "$(makevn_state_dir "$1")"
}

makevn_config_path() {
  printf '%s/config\n' "$(makevn_state_dir "$1")"
}

makevn_profile_path() {
  printf '%s/profile.env\n' "$(makevn_state_dir "$1")"
}

makevn_logs_dir() {
  printf '%s/logs\n' "$(makevn_state_dir "$1")"
}

makevn_load_config() {
  local repo_root="$1"
  local config_path
  config_path="$(makevn_config_path "${repo_root}")"
  if [[ -f "${config_path}" ]]; then
    # shellcheck source=/dev/null
    source "${config_path}"
  fi
}

makevn_load_profile() {
  local repo_root="$1"
  local profile_path
  profile_path="$(makevn_profile_path "${repo_root}")"
  if [[ -f "${profile_path}" ]]; then
    # shellcheck source=/dev/null
    source "${profile_path}"
  fi
}

makevn_effective_local_containers() {
  local repo_root="$1"
  local fallback="${2:-}"

  makevn_load_config "${repo_root}"
  if [[ -n "${LOCAL_CONTAINERS+x}" ]]; then
    printf '%s\n' "${LOCAL_CONTAINERS}"
  elif [[ -n "${MAKEVN_LOCAL_CONTAINERS+x}" ]]; then
    printf '%s\n' "${MAKEVN_LOCAL_CONTAINERS}"
  else
    printf '%s\n' "${fallback}"
  fi
}

makevn_json_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"

  printf '%s' "${value}"
}

makevn_has_word() {
  local list="$1"
  local word="$2"
  local item

  for item in ${list}; do
    if [[ "${item}" == "${word}" ]]; then
      return 0
    fi
  done

  return 1
}

makevn_append_word() {
  local list="$1"
  local word="$2"

  if [[ -z "${word}" ]]; then
    printf '%s\n' "${list}"
    return 0
  fi

  if makevn_has_word "${list}" "${word}"; then
    printf '%s\n' "${list}"
    return 0
  fi

  if [[ -n "${list}" ]]; then
    printf '%s %s\n' "${list}" "${word}"
    return 0
  fi

  printf '%s\n' "${word}"
}

makevn_merge_words() {
  local base="$1"
  local extra="$2"
  local word

  for word in ${extra}; do
    base="$(makevn_append_word "${base}" "${word}")"
  done

  printf '%s\n' "${base}"
}

makevn_trim() {
  printf '%s\n' "$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
}
