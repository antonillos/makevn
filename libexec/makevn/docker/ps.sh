#!/usr/bin/env bash
set -euo pipefail

compose_args="${COMPOSE_ARGS:-}"
services="${SERVICES:-}"
docker_compose="${DOCKER_COMPOSE:-}"
show_all_containers="${SHOW_ALL_CONTAINERS:-false}"

if [[ -n "${services}" && -z "${compose_args}" ]]; then
  printf 'ERR: COMPOSE_ARGS is required when SERVICES is provided\n' >&2
  exit 1
fi

if [[ -z "${docker_compose}" ]]; then
  if command -v docker-compose >/dev/null 2>&1; then
    docker_compose="docker-compose"
  else
    docker_compose="docker compose"
  fi
fi

if [[ "${show_all_containers}" == "true" || -z "${services}" ]]; then
  printf '%-28s %-12s %-12s %-12s\n' 'NAME' 'STATE' 'HEALTH' 'CONTAINER'
  printf '%-28s %-12s %-12s %-12s\n' '----' '-----' '------' '---------'
  while IFS= read -r cid; do
    [[ -n "${cid}" ]] || continue
    name="$(docker inspect -f '{{.Name}}' "${cid}" 2>/dev/null | sed 's#^/##')"
    state="$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null || printf 'unknown')"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || printf 'unknown')"
    printf '%-28s %-12s %-12s %-12s\n' "${name}" "${state}" "${health}" "${cid:0:12}"
  done <<< "$(docker ps -aq)"
  exit 0
fi

has_errors=false
declare -a rows=()

for service in ${services}; do
  cid="$(${docker_compose} ${compose_args} ps -q "${service}" 2>/dev/null || true)"

  if [[ -z "${cid}" ]]; then
    has_errors=true
    rows+=("${service}|missing|-|-")
    continue
  fi

  state="$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null || printf 'unknown')"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || printf 'unknown')"

  if [[ "${state}" != "running" || ("${health}" != "none" && "${health}" != "healthy") ]]; then
    has_errors=true
  fi

  rows+=("${service}|${state}|${health}|${cid:0:12}")
done

if [[ "${has_errors}" == "true" ]]; then
  printf '\n%-28s %-12s %-12s %-12s\n' 'NAME' 'STATE' 'HEALTH' 'CONTAINER'
  printf '%-28s %-12s %-12s %-12s\n' '----' '-----' '------' '---------'
  for row in "${rows[@]}"; do
    IFS='|' read -r name state health cid <<< "${row}"
    printf '%-28s %-12s %-12s %-12s\n' "${name}" "${state}" "${health}" "${cid}"
  done
fi
