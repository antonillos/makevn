#!/usr/bin/env bash

makevn_collect_compose_args() {
  local compose_file="$1"
  local compose_override_file="$2"
  local repo_root="${3:-${PWD}}"

  if [[ "${MAKEVN_COMPOSE_PROJECT_SCOPE:-}" == worktree ]]; then
    python3 "$(dirname "${BASH_SOURCE[0]}")/project_scope.py" "${repo_root}" "${compose_file}" || return $?
  fi

  printf '%s\n' "-f"
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${compose_file}"
  if [[ -f "${compose_override_file}" ]]; then
    printf '%s\n' "-f"
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${compose_override_file}"
  fi
}
