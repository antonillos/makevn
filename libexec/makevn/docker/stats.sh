#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=compose_args.sh
source "$(dirname "${BASH_SOURCE[0]}")/compose_args.sh"
selected_args=()
if [[ -n "${MAKEVN_EXECUTION_COMPOSE_FILE:-}" ]]; then
  [[ "${MAKEVN_EXECUTION_COMPOSE_FILE}" != none ]] || { printf 'ERR: Compose is disabled\n' >&2; exit 1; }
  while IFS= read -r arg; do
    selected_args+=("${arg}")
  done < <(makevn_collect_compose_args "${MAKEVN_EXECUTION_COMPOSE_FILE}" "$(dirname "${MAKEVN_EXECUTION_COMPOSE_FILE}")/docker-compose.override.yml")
fi

if ! command -v docker >/dev/null 2>&1; then
  printf 'ERR: docker is not available\n' >&2
  exit 1
fi

containers=()
if [[ -n "${MAKEVN_EXECUTION_COMPOSE_FILE:-}" ]]; then
  if command -v docker-compose >/dev/null 2>&1; then
    ids="$(docker-compose "${selected_args[@]}" ps -q)"
  else
    ids="$(docker compose "${selected_args[@]}" ps -q)"
  fi
  while IFS= read -r id; do
    [[ -z "${id}" ]] || containers+=("${id}")
  done <<< "${ids}"
  [[ ${#containers[@]} -gt 0 ]] || { printf 'No running containers for the selected Compose file.\n'; exit 0; }
fi
docker stats --no-stream "${containers[@]}" --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'
