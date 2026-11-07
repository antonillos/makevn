#!/usr/bin/env bash

makevn_collect_compose_args() {
  local compose_file="$1"
  local compose_override_file="$2"

  printf '%s\n' "-f"
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${compose_file}"
  if [[ -f "${compose_override_file}" ]]; then
    printf '%s\n' "-f"
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${compose_override_file}"
  fi
}
