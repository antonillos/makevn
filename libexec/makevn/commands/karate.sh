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
  if [[ "${MAKEVN_KARATE_CONTAINERS_CHECKED:-}" != "yes" ]]; then
    cmd_docker_ps_required "${repo_root}" --compose karate
  fi

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

# Record actual completion, not metadata transitions (which may repeat).
makevn_run_karate_phase() (
  local phase="$1"
  shift
  if [[ -n "${MAKEVN_BACKEND_PHASE_DIR:-}" ]]; then
    local record="${MAKEVN_BACKEND_PHASE_DIR}/${phase}"
    local started="${SECONDS}"
    [[ -z "${MAKEVN_BACKEND_DETAIL_OUT:-}" ]] || : > "${MAKEVN_BACKEND_DETAIL_OUT}"
    local title="${1#cmd_}" repo="$2"
    title="${title//_/-}"
    trap '
      rc=$?
      if grep -Fqx "title=${title}" "${MAKEVN_BACKEND_METADATA_OUT}" 2>/dev/null; then
        cp "${MAKEVN_BACKEND_METADATA_OUT}" "${record}"
      else
        printf "command=%s\nrepo=%s\ncwd=%s\nlog_path=\nrelative_log_path=\ncommand_display=%s\ntitle=%s\n" "${title}" "${repo}" "${repo}" "${title}" "${title}" > "${record}"
      fi
      printf "\nduration_seconds=%s\nexit_code=%s\n" "$((SECONDS - started))" "${rc}" >> "${record}"
      [[ -z "${MAKEVN_BACKEND_DETAIL_OUT:-}" ]] || cp "${MAKEVN_BACKEND_DETAIL_OUT}" "${record}.detail"
      exit "${rc}"
    ' EXIT
  fi
  "$@"
)

cmd_karate_all() {
  local repo_root="$1"
  local test_rc=0
  local maven_base_path=""
  local health_url=""
  local health_timeout=""

  shift

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if ! makevn_detect_app_runnable "${repo_root}" "${maven_base_path}"; then
    makevn_die "karate-all is disabled: no executable application was detected for run-app-bg. Use karate-test directly when tests do not need a local app."
  fi

  makevn_load_config "${repo_root}"
  health_url="$(makevn_app_health_url "${repo_root}" "${maven_base_path}" || true)"
  [[ -n "${health_url}" ]] || makevn_die "karate-all requires application HTTP readiness. Configure MAKEVN_APP_HEALTH_URL in .makevn/config, then retry."
  health_timeout="${MAKEVN_APP_HEALTH_TIMEOUT:-60}"
  makevn_validate_app_health_timeout "${health_timeout}"

  makevn_resolve_karate_profiles "${repo_root}"
  if [[ "${MAKEVN_DETECTED_KARATE_APP_PROFILES_STATUS}" == ambiguous && -z "${SPRING_PROFILES_ACTIVE+x}" && -z "${MAKEVN_KARATE_APP_PROFILES:-}" ]]; then
    makevn_die "Ambiguous Karate Spring profiles: ${MAKEVN_DETECTED_KARATE_APP_PROFILES_CANDIDATES}. Configure MAKEVN_KARATE_APP_PROFILES in .makevn/config or set SPRING_PROFILES_ACTIVE explicitly."
  fi
  if [[ "${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE}" == config* && ! "${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES}" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]]; then
    makevn_die "Invalid MAKEVN_KARATE_APP_PROFILES: use a comma-separated list of literal Spring profile names."
  fi
  makevn_report_run_detail "Karate application profiles: ${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES:-application defaults} (${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE})"
  if [[ -z "${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES}" ]]; then
    makevn_report_run_detail "No explicit Karate profiles selected. If CI requires profiles, configure MAKEVN_KARATE_APP_PROFILES in .makevn/config."
  fi

  makevn_run_karate_phase 1 cmd_karate_docker_up "${repo_root}"

  if [[ "${SKIP_PACKAGE:-false}" == "false" ]]; then
    makevn_run_karate_phase 2 cmd_package "${repo_root}"
  else
    printf '%s\n' "$(makevn_dim "Skipping package step (SKIP_PACKAGE=true)")"
  fi

  if [[ -n "${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES}" ]]; then
    SPRING_PROFILES_ACTIVE="${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES}" makevn_run_karate_phase 3 cmd_run_app_bg "${repo_root}" "${health_url}" "${health_timeout}"
  else
    makevn_run_karate_phase 3 cmd_run_app_bg "${repo_root}" "${health_url}" "${health_timeout}"
  fi
  trap 'cmd_stop_app "'"${repo_root}"'" >/dev/null 2>&1 || true' EXIT INT TERM

  makevn_run_karate_phase 4 cmd_docker_ps_required "${repo_root}" --compose karate
  set +e
  MAKEVN_KARATE_CONTAINERS_CHECKED=yes makevn_run_karate_phase 5 cmd_karate_test "${repo_root}" "$@"
  test_rc=$?
  set -e

  cmd_stop_app "${repo_root}"
  trap - EXIT INT TERM
  return "${test_rc}"
}
