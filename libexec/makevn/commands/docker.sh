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

makevn_parse_docker_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail)
        shift
        ;;
      *)
        makevn_die "Unknown docker option: $1"
        ;;
    esac
  done
}

makevn_docker_compose_file_for_kind() {
  local repo_root="$1"
  local compose_kind="$2"

  case "${compose_kind}" in
    boot)
      makevn_boot_compose_file_path "${repo_root}"
      ;;
    karate)
      makevn_karate_compose_file_path "${repo_root}"
      ;;
    *)
      makevn_die "Unknown docker compose selection: ${compose_kind}. Expected boot or karate."
      ;;
  esac
}

makevn_docker_compose_override_file_for_kind() {
  local repo_root="$1"
  local compose_kind="$2"

  case "${compose_kind}" in
    boot)
      makevn_boot_compose_override_file_path "${repo_root}"
      ;;
    karate)
      makevn_karate_compose_override_file_path "${repo_root}"
      ;;
    *)
      makevn_die "Unknown docker compose selection: ${compose_kind}. Expected boot or karate."
      ;;
  esac
}

makevn_wait_for_required_docker_services() {
  local repo_root="$1"
  local compose_file="$2"
  local compose_override_file="$3"
  local docker_compose_cmd="$4"
  local docker_ps_script="${MAKEVN_LIBEXEC_DIR}/docker/ps.sh"
  local extract_services_script="${MAKEVN_LIBEXEC_DIR}/docker/extract_services.sh"
  local services=""
  local compose_args=""
  local output=""
  local deadline=0

  [[ -f "${docker_ps_script}" && -f "${extract_services_script}" ]] || makevn_die "Docker helper scripts not found"

  services="$(bash "${extract_services_script}" "${compose_file}" || true)"
  [[ -n "${services}" ]] || makevn_die "No services defined in compose file: ${compose_file}"

  compose_args="-f ${compose_file}"
  if [[ -f "${compose_override_file}" ]]; then
    compose_args+=" -f ${compose_override_file}"
  fi

  deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    output="$(cd "${repo_root}" && COMPOSE_ARGS="${compose_args}" SERVICES="${services}" DOCKER_COMPOSE="${docker_compose_cmd}" bash "${docker_ps_script}" || true)"
    if [[ -z "${output}" ]]; then
      return 0
    fi
    sleep 2
  done

  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}"
  fi
  makevn_die "Required Docker services did not become running and healthy after docker-up."
}

print_boot_docker_service_issues() {
  local repo_root="$1"
  local compose_file=""
  local compose_override_file=""
  local docker_ps_script="${MAKEVN_LIBEXEC_DIR}/docker/ps.sh"
  local extract_services_script="${MAKEVN_LIBEXEC_DIR}/docker/extract_services.sh"
  local services=""
  local docker_compose_cmd=""
  local compose_args=""
  local output=""

  compose_file="$(makevn_boot_compose_file_path "${repo_root}" || true)"
  compose_override_file="$(makevn_boot_compose_override_file_path "${repo_root}" || true)"
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

cmd_docker_ps_required() {
  local repo_root="$1"
  local compose_kind="boot"
  local compose_file=""
  local compose_override_file=""
  local docker_ps_script="${MAKEVN_LIBEXEC_DIR}/docker/ps.sh"
  local extract_services_script="${MAKEVN_LIBEXEC_DIR}/docker/extract_services.sh"
  local services=""
  local docker_compose_cmd=""
  local compose_args=""

  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail)
        shift
        ;;
      --compose)
        [[ $# -ge 2 ]] || makevn_die "Missing value for --compose"
        compose_kind="$2"
        shift 2
        ;;
      *)
        makevn_die "Unknown docker option: $1"
        ;;
    esac
  done

  compose_file="$(makevn_docker_compose_file_for_kind "${repo_root}" "${compose_kind}" || true)"
  compose_override_file="$(makevn_docker_compose_override_file_for_kind "${repo_root}" "${compose_kind}" || true)"
  [[ -f "${compose_file}" ]] || makevn_die "Docker compose file not found for ${compose_kind}: ${compose_file}"
  [[ -f "${docker_ps_script}" && -f "${extract_services_script}" ]] || makevn_die "Docker helper scripts not found"

  services="$(bash "${extract_services_script}" "${compose_file}" || true)"
  [[ -n "${services}" ]] || makevn_die "No services defined in compose file: ${compose_file}"

  docker_compose_cmd="$(makevn_resolve_docker_compose_command || true)"
  [[ -n "${docker_compose_cmd}" ]] || makevn_die "Neither docker-compose nor 'docker compose' is available."

  compose_args="-f ${compose_file}"
  if [[ -f "${compose_override_file}" ]]; then
    compose_args+=" -f ${compose_override_file}"
  fi

  if ! makevn_run_logged "${repo_root}" docker-ps-required docker-ps-required docker-ps-required bash -c '
    output="$(COMPOSE_ARGS="$1" SERVICES="$2" DOCKER_COMPOSE="$3" bash "$4" || true)"
    if [[ -n "${output}" ]]; then
      printf "%s\n" "${output}"
      exit 1
    fi
  ' bash "${compose_args}" "${services}" "${docker_compose_cmd}" "${docker_ps_script}"; then
    makevn_die "Required Docker services are not running or healthy. Run 'makevn docker-up' first."
  fi
}

cmd_docker_up() {
  local repo_root="$1"
  local compose_file=""
  local compose_override_file=""
  local docker_compose_cmd=""
  local compose_error=""
  local -a docker_compose=()
  local -a compose_args=()

  shift
  makevn_parse_docker_args "$@"

  compose_file="$(makevn_boot_compose_file_path "${repo_root}" || true)"
  compose_override_file="$(makevn_boot_compose_override_file_path "${repo_root}" || true)"
  if [[ ! -f "${compose_file}" ]]; then
    compose_error="$(makevn_boot_compose_resolution_error "${repo_root}")"
    makevn_die "Docker compose file not found. ${compose_error}"
  fi

  docker_compose_cmd="$(makevn_resolve_docker_compose_command || true)"
  [[ -n "${docker_compose_cmd}" ]] || makevn_die "Neither docker-compose nor 'docker compose' is available."
  read -r -a docker_compose <<< "${docker_compose_cmd}"

  while IFS= read -r arg; do
    compose_args+=("${arg}")
  done < <(makevn_collect_compose_args "${compose_file}" "${compose_override_file}")

  makevn_run_logged "${repo_root}" docker-up docker-up docker-up bash -c '
    "$@" down -v --remove-orphans
    docker volume prune -f
    "$@" up --detach
  ' bash "${docker_compose[@]}" "${compose_args[@]}"
  makevn_wait_for_required_docker_services "${repo_root}" "${compose_file}" "${compose_override_file}" "${docker_compose_cmd}"
}

cmd_docker_down() {
  local repo_root="$1"
  local compose_file=""
  local compose_override_file=""
  local docker_compose_cmd=""
  local compose_error=""
  local -a docker_compose=()
  local -a compose_args=()

  shift
  makevn_parse_docker_args "$@"

  compose_file="$(makevn_boot_compose_file_path "${repo_root}" || true)"
  compose_override_file="$(makevn_boot_compose_override_file_path "${repo_root}" || true)"
  if [[ ! -f "${compose_file}" ]]; then
    compose_error="$(makevn_boot_compose_resolution_error "${repo_root}")"
    makevn_die "Docker compose file not found. ${compose_error}"
  fi

  docker_compose_cmd="$(makevn_resolve_docker_compose_command || true)"
  [[ -n "${docker_compose_cmd}" ]] || makevn_die "Neither docker-compose nor 'docker compose' is available."
  read -r -a docker_compose <<< "${docker_compose_cmd}"

  while IFS= read -r arg; do
    compose_args+=("${arg}")
  done < <(makevn_collect_compose_args "${compose_file}" "${compose_override_file}")

  makevn_run_logged "${repo_root}" docker-down docker-down docker-down bash -c '
    "$@" down -v --remove-orphans
    docker volume prune -f
  ' bash "${docker_compose[@]}" "${compose_args[@]}"
}

cmd_docker_ps() {
  local repo_root="$1"
  local docker_ps_script="${MAKEVN_LIBEXEC_DIR}/docker/ps.sh"

  shift
  makevn_parse_docker_args "$@"

  [[ -f "${docker_ps_script}" ]] || makevn_die "Docker ps helper script not found: ${docker_ps_script}"

  makevn_run_logged "${repo_root}" docker-ps docker-ps docker-ps bash "${docker_ps_script}"
}
