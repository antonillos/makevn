#!/usr/bin/env bash
set -euo pipefail

makevn_collect_karate_compose_args() {
  local compose_file="$1"
  local compose_override_file="$2"

  printf '%s\n' "-f"
  printf '%s\n' "${compose_file}"
  if [[ -f "${compose_override_file}" ]]; then
    printf '%s\n' "-f"
    printf '%s\n' "${compose_override_file}"
  fi
}

makevn_wait_app_health() {
  local health_url="$1"
  local timeout_seconds="${2:-120}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if curl -fsS "${health_url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  makevn_die "App health check did not pass within ${timeout_seconds}s: ${health_url}"
}

cmd_karate_docker_down() {
  local repo_root="$1"
  local compose_file=""
  local compose_override_file=""
  local docker_compose_cmd=""
  local -a docker_compose=()
  local -a compose_args=()

  shift
  makevn_parse_docker_args "$@"

  compose_file="$(makevn_karate_compose_file_path "${repo_root}" || true)"
  compose_override_file="$(makevn_karate_compose_override_file_path "${repo_root}" || true)"
  [[ -f "${compose_file}" ]] || makevn_die "Karate docker compose file not found. Configure MAKEVN_E2E_COMPOSE_FILE or add e2e/karate/src/test/resources/compose/docker-compose.yml."

  docker_compose_cmd="$(makevn_resolve_docker_compose_command || true)"
  [[ -n "${docker_compose_cmd}" ]] || makevn_die "Neither docker-compose nor 'docker compose' is available."
  read -r -a docker_compose <<< "${docker_compose_cmd}"

  while IFS= read -r arg; do
    compose_args+=("${arg}")
  done < <(makevn_collect_karate_compose_args "${compose_file}" "${compose_override_file}")

  makevn_run_logged "${repo_root}" karate-docker-down karate-docker-down karate-docker-down bash -c '
    "$@" down -v --remove-orphans
    docker volume prune -f
  ' bash "${docker_compose[@]}" "${compose_args[@]}"
}

cmd_karate_docker_up() {
  local repo_root="$1"
  local compose_file=""
  local compose_override_file=""
  local docker_compose_cmd=""
  local profile="${PROFILE:-}"
  local -a docker_compose=()
  local -a compose_args=()

  shift
  makevn_parse_docker_args "$@"

  compose_file="$(makevn_karate_compose_file_path "${repo_root}" || true)"
  compose_override_file="$(makevn_karate_compose_override_file_path "${repo_root}" || true)"
  [[ -f "${compose_file}" ]] || makevn_die "Karate docker compose file not found. Configure MAKEVN_E2E_COMPOSE_FILE or add e2e/karate/src/test/resources/compose/docker-compose.yml."

  docker_compose_cmd="$(makevn_resolve_docker_compose_command || true)"
  [[ -n "${docker_compose_cmd}" ]] || makevn_die "Neither docker-compose nor 'docker compose' is available."
  read -r -a docker_compose <<< "${docker_compose_cmd}"

  while IFS= read -r arg; do
    compose_args+=("${arg}")
  done < <(makevn_collect_karate_compose_args "${compose_file}" "${compose_override_file}")

  if [[ -n "${profile}" ]]; then
    makevn_run_logged "${repo_root}" karate-docker-up karate-docker-up karate-docker-up bash -c '
      profile="$1"
      shift
      "$@" down -v --remove-orphans
      docker volume prune -f
      "$@" --profile "${profile}" up --detach
    ' bash "${profile}" "${docker_compose[@]}" "${compose_args[@]}"
  else
    makevn_run_logged "${repo_root}" karate-docker-up karate-docker-up karate-docker-up bash -c '
      "$@" down -v --remove-orphans
      docker volume prune -f
      "$@" up --detach
    ' bash "${docker_compose[@]}" "${compose_args[@]}"
  fi
}

cmd_karate_test() {
  local repo_root="$1"
  local karate_base_path=""
  local maven_executable=""
  local test_tag="${TEST_TAG:-}"
  local cli_flags_value=""
  local -a cli_flags=()
  local -a maven_args=()
  local -a extra_args=()

  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)
        [[ $# -ge 2 ]] || makevn_die "Missing value for --tag"
        test_tag="$2"
        shift 2
        ;;
      --)
        shift
        extra_args=("$@")
        break
        ;;
      *)
        makevn_die "Unknown karate-test option: $1"
        ;;
    esac
  done

  karate_base_path="$(makevn_detect_karate_base_path "${repo_root}" || true)"
  [[ -n "${karate_base_path}" ]] || makevn_die "No Karate Maven project detected. Expected e2e/karate/pom.xml or karate/pom.xml."
  cmd_docker_ps_required "${repo_root}" --compose karate

  maven_executable="$(makevn_maven_executable "${repo_root}" "${karate_base_path}")"
  cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" test)"
  cli_flags_value="$(makevn_append_word "${cli_flags_value}" "-nsu")"

  maven_args=("${maven_executable}")
  if [[ -n "${cli_flags_value}" ]]; then
    read -r -a cli_flags <<< "${cli_flags_value}"
    maven_args+=("${cli_flags[@]}")
  fi
  maven_args+=(-f "${karate_base_path}/pom.xml" test -Dkarate.env=local "-Dkarate.report.options=--showLog true")
  if [[ -n "${test_tag}" ]]; then
    maven_args+=("-Dkarate.options=-t${test_tag}")
  fi
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    maven_args+=("${extra_args[@]}")
  fi

  MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" karate "${karate_base_path}" karate-test karate-test karate-test "${maven_args[@]}"
}

cmd_karate_all() {
  local repo_root="$1"
  local test_rc=0
  local maven_base_path=""

  shift

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if ! makevn_detect_app_runnable "${repo_root}" "${maven_base_path}"; then
    makevn_die "karate-all is disabled: no executable application was detected for run-app-bg. Use karate-test directly when tests do not need a local app."
  fi

  cmd_karate_docker_up "${repo_root}"

  if [[ "${SKIP_PACKAGE:-false}" == "false" ]]; then
    cmd_package "${repo_root}"
  else
    printf '%s\n' "$(makevn_dim "Skipping package step (SKIP_PACKAGE=true)")"
  fi

  cmd_run_app_bg "${repo_root}"
  trap 'cmd_stop_app "'"${repo_root}"'" >/dev/null 2>&1 || true' EXIT INT TERM

  set +e
  cmd_karate_test "${repo_root}" "$@"
  test_rc=$?
  set -e

  cmd_stop_app "${repo_root}"
  trap - EXIT INT TERM
  return "${test_rc}"
}
