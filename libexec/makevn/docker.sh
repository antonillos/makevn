#!/usr/bin/env bash

makevn_resolve_docker_compose_command() {
  if command -v docker-compose >/dev/null 2>&1; then
    printf 'docker-compose\n'
  elif docker compose version >/dev/null 2>&1; then
    printf 'docker compose\n'
  else
    return 1
  fi
}

makevn_collect_compose_args() {
  local compose_file="$1"
  local compose_override_file="$2"

  printf '%s\n' "-f"
  printf '%s\n' "${compose_file}"
  if [[ -f "${compose_override_file}" ]]; then
    printf '%s\n' "-f"
    printf '%s\n' "${compose_override_file}"
  fi
}

print_boot_docker_service_issues() {
  local repo_root="$1"
  local compose_file=""
  local compose_override_file=""
  local docker_ps_script="${MAKEVN_INSTALL_ROOT}/libexec/makevn/docker_ps.sh"
  local extract_services_script="${MAKEVN_INSTALL_ROOT}/libexec/makevn/extract_services.sh"
  local services=""
  local docker_compose_cmd=""
  local compose_args=""
  local output=""

  compose_file="$(makevn_boot_compose_file_path "${repo_root}")"
  compose_override_file="$(makevn_boot_compose_override_file_path "${repo_root}")"
  [[ -f "${compose_file}" ]] || return 0
  [[ -f "${docker_ps_script}" && -f "${extract_services_script}" ]] || return 0

  services="$(bash "${extract_services_script}" "${compose_file}" || true)"
  [[ -n "${services}" ]] || return 0

  docker_compose_cmd="$(makevn_resolve_docker_compose_command || true)"
  [[ -n "${docker_compose_cmd}" ]] || return 0

  compose_args="-f ${compose_file}"
  if [[ -f "${compose_override_file}" ]]; then
    compose_args+=" -f ${compose_override_file}"
  fi

  output="$(cd "${repo_root}" && COMPOSE_ARGS="${compose_args}" SERVICES="${services}" DOCKER_COMPOSE="${docker_compose_cmd}" bash "${docker_ps_script}" || true)"
  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}"
  fi
}

cmd_docker_up() {
  local repo_root="$1"
  local compose_file=""
  local compose_override_file=""
  local docker_compose_cmd=""
  local -a docker_compose=()
  local -a compose_args=()

  compose_file="$(makevn_boot_compose_file_path "${repo_root}")"
  compose_override_file="$(makevn_boot_compose_override_file_path "${repo_root}")"
  [[ -f "${compose_file}" ]] || makevn_die "Docker compose file not found: ${compose_file}"

  docker_compose_cmd="$(makevn_resolve_docker_compose_command || true)"
  [[ -n "${docker_compose_cmd}" ]] || makevn_die "Neither docker-compose nor 'docker compose' is available."
  read -r -a docker_compose <<< "${docker_compose_cmd}"

  while IFS= read -r arg; do
    compose_args+=("${arg}")
  done < <(makevn_collect_compose_args "${compose_file}" "${compose_override_file}")

  print_command_intro "${repo_root}" docker-up
  makevn_trace_command exec "${docker_compose[@]}" "${compose_args[@]}" down -v --remove-orphans
  (cd "${repo_root}" && "${docker_compose[@]}" "${compose_args[@]}" down -v --remove-orphans)
  makevn_trace_command exec docker volume prune -f
  (cd "${repo_root}" && docker volume prune -f)
  makevn_trace_command exec "${docker_compose[@]}" "${compose_args[@]}" up --detach
  (cd "${repo_root}" && "${docker_compose[@]}" "${compose_args[@]}" up --detach)
}

cmd_docker_down() {
  local repo_root="$1"
  local compose_file=""
  local compose_override_file=""
  local docker_compose_cmd=""
  local -a docker_compose=()
  local -a compose_args=()

  compose_file="$(makevn_boot_compose_file_path "${repo_root}")"
  compose_override_file="$(makevn_boot_compose_override_file_path "${repo_root}")"
  [[ -f "${compose_file}" ]] || makevn_die "Docker compose file not found: ${compose_file}"

  docker_compose_cmd="$(makevn_resolve_docker_compose_command || true)"
  [[ -n "${docker_compose_cmd}" ]] || makevn_die "Neither docker-compose nor 'docker compose' is available."
  read -r -a docker_compose <<< "${docker_compose_cmd}"

  while IFS= read -r arg; do
    compose_args+=("${arg}")
  done < <(makevn_collect_compose_args "${compose_file}" "${compose_override_file}")

  print_command_intro "${repo_root}" docker-down
  makevn_trace_command exec "${docker_compose[@]}" "${compose_args[@]}" down -v --remove-orphans
  (cd "${repo_root}" && "${docker_compose[@]}" "${compose_args[@]}" down -v --remove-orphans)
  makevn_trace_command exec docker volume prune -f
  (cd "${repo_root}" && docker volume prune -f)
}

cmd_docker_ps() {
  local repo_root="$1"
  local docker_ps_script="${MAKEVN_INSTALL_ROOT}/libexec/makevn/docker_ps.sh"

  [[ -f "${docker_ps_script}" ]] || makevn_die "Docker ps helper script not found: ${docker_ps_script}"

  print_command_intro "${repo_root}" docker-ps
  makevn_trace_command exec bash "${docker_ps_script}"
  (cd "${repo_root}" && bash "${docker_ps_script}")
}
