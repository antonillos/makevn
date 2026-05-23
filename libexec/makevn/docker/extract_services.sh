#!/usr/bin/env bash
set -euo pipefail

compose_file="${1:-.}"
in_services=0
current_service=""
current_has_profile=0
result=''

[[ -f "${compose_file}" ]] || exit 0

append_current_service() {
  if [[ -n "${current_service}" && ${current_has_profile} -eq 0 ]]; then
    result+="${current_service} "
  fi
}

while IFS= read -r line || [[ -n "${line}" ]]; do
  if [[ "${line}" =~ ^services:[[:space:]]*$ ]]; then
    in_services=1
    continue
  fi

  [[ ${in_services} -eq 1 ]] || continue

  if [[ "${line}" =~ ^[A-Za-z0-9_.-]+: ]]; then
    append_current_service
    break
  fi

  if [[ "${line}" =~ ^[[:space:]]{2}([A-Za-z0-9_.-]+):[[:space:]]*$ ]]; then
    append_current_service
    current_service="${BASH_REMATCH[1]}"
    current_has_profile=0
    continue
  fi

  if [[ -n "${current_service}" && "${line}" =~ ^[[:space:]]+profiles: ]]; then
    current_has_profile=1
  fi
done < "${compose_file}"

append_current_service

printf '%s\n' "${result}"
