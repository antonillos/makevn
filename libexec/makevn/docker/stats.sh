#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  printf 'ERR: docker is not available\n' >&2
  exit 1
fi

containers=()
if [[ -n "${MAKEVN_EXECUTION_COMPOSE_FILE:-}" ]]; then
  [[ "${MAKEVN_EXECUTION_COMPOSE_FILE}" != none ]] || { printf 'ERR: Compose is disabled\n' >&2; exit 1; }
  if command -v docker-compose >/dev/null 2>&1; then
    ids="$(docker-compose -f "${MAKEVN_EXECUTION_COMPOSE_FILE}" ps -q)"
  else
    ids="$(docker compose -f "${MAKEVN_EXECUTION_COMPOSE_FILE}" ps -q)"
  fi
  while IFS= read -r id; do
    [[ -z "${id}" ]] || containers+=("${id}")
  done <<< "${ids}"
  [[ ${#containers[@]} -gt 0 ]] || { printf 'No running containers for the selected Compose file.\n'; exit 0; }
fi
docker stats --no-stream "${containers[@]}" --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'
