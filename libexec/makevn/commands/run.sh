#!/usr/bin/env bash
set -euo pipefail

cmd_run() {
  local repo_root="$1"
  local maven_base_path
  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  print_command_intro "${repo_root}" run
  makevn_run_command_configured "${repo_root}" "${maven_base_path}"
}

makevn_app_log_dir() {
  printf '%s/app\n' "$(makevn_state_dir "$1")"
}

makevn_detect_app_jar() {
  local maven_base_path="$1"
  local boot_module="$2"
  local first_candidate=""
  local candidate=""

  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    if [[ -z "${first_candidate}" ]]; then
      first_candidate="${candidate}"
    fi
    if makevn_app_jar_has_main_class "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(find "${maven_base_path}/${boot_module}/target" \
    -name "*.jar" \
    -not -name "*-sources.jar" \
    -not -name "*.original" \
    -not -name "*-tests.jar" \
    -type f \
    2>/dev/null \
    | grep -v "original" \
    | LC_ALL=C sort \
  )

  if [[ -n "${first_candidate}" ]]; then
    printf '%s\n' "${first_candidate}"
    return 0
  fi

  return 1
}

makevn_app_jar_manifest() {
  local jar_file="$1"

  unzip -p "${jar_file}" META-INF/MANIFEST.MF 2>/dev/null || true
}

makevn_app_jar_has_main_class() {
  local jar_file="$1"

  makevn_app_jar_manifest "${jar_file}" | grep -q '^Main-Class: '
}

makevn_app_jar_manifest_value() {
  local jar_file="$1"
  local key="$2"

  makevn_app_jar_manifest "${jar_file}" \
    | sed -nE "s/^${key}: //p" \
    | tr -d '\r' \
    | head -n 1
}

makevn_app_health_url() {
  local repo_root="$1"
  local maven_base_path="$2"

  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_APP_HEALTH_URL:-}" ]]; then
    printf '%s\n' "${MAKEVN_APP_HEALTH_URL}"
    return 0
  fi

  makevn_load_profile "${repo_root}"
  if [[ -n "${MAKEVN_PROFILE_APP_HEALTH_URL:-}" ]]; then
    printf '%s\n' "${MAKEVN_PROFILE_APP_HEALTH_URL}"
    return 0
  fi

  makevn_detect_app_health_url "${maven_base_path}" \
    || makevn_die "Could not detect application health URL. Run 'makevn doctor' or set MAKEVN_APP_HEALTH_URL in .makevn/config."
}

makevn_repo_has_legacy_local_containers_default() {
  local repo_root="$1"
  local makefile=""

  for makefile in "${repo_root}/GNUmakefile" "${repo_root}/Makefile"; do
    [[ -f "${makefile}" ]] || continue
    grep -q 'LOCAL_TEST[[:space:]]*?=[[:space:]]*TRUE' "${makefile}" || continue
    grep -q 'export[[:space:]]\+LOCAL_CONTAINERS[[:space:]]*:=' "${makefile}" || continue
    return 0
  done

  return 1
}

makevn_effective_app_local_containers() {
  local repo_root="$1"

  makevn_load_config "${repo_root}"
  if [[ -n "${LOCAL_CONTAINERS+x}" ]]; then
    printf '%s\n' "${LOCAL_CONTAINERS}"
    return 0
  fi
  if [[ -n "${MAKEVN_LOCAL_CONTAINERS+x}" ]]; then
    printf '%s\n' "${MAKEVN_LOCAL_CONTAINERS}"
    return 0
  fi
  if makevn_repo_has_legacy_local_containers_default "${repo_root}"; then
    printf '%s\n' "${LOCAL_TEST:-TRUE}"
    return 0
  fi

  return 1
}

makevn_wait_app_health() {
  local health_url="$1"
  local timeout_seconds="${2:-30}"
  local app_pid="${3:-}"
  local log_file="${4:-}"
  local elapsed=0
  local app_state=""

  while (( elapsed < timeout_seconds )); do
    if curl -fsS "${health_url}" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "${app_pid}" ]]; then
      app_state="$(ps -p "${app_pid}" -o stat= 2>/dev/null || true)"
      if [[ -z "${app_state}" || "${app_state}" == Z* ]]; then
        if [[ -n "${log_file}" ]]; then
          printf '%s\n' "$(makevn_warn "Error: Application process exited during startup. Check the log: ${log_file}")" >&2
          makevn_print_app_log_excerpt "${log_file}" >&2
        else
          printf '%s\n' "$(makevn_warn "Error: Application process exited during startup.")" >&2
        fi
        return 1
      fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  printf '%s\n' "$(makevn_warn "Error: App health check did not pass within ${timeout_seconds}s: ${health_url}")" >&2
  makevn_print_app_log_excerpt "${log_file}" >&2
  return 1
}

makevn_print_app_log_excerpt() {
  local log_file="$1"
  local lines="${MAKEVN_APP_LOG_TAIL_LINES:-80}"

  [[ -n "${log_file}" && -f "${log_file}" ]] || return 0

  printf '%s\n' "$(makevn_dim "last ${lines} log lines:")"
  tail -n "${lines}" "${log_file}" 2>/dev/null || true
}

makevn_start_app_background() {
  local repo_root="$1"
  local mode="$2"
  local maven_base_path=""
  local boot_module=""
  local java_home=""
  local jar_file=""
  local jar_main_class=""
  local jar_start_class=""
  local health_url=""
  local local_containers=""
  local log_dir=""
  local log_file=""
  local pid_file=""
  local jar_record=""
  local existing_pid=""
  local existing_cmd=""
  local app_pid=""

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${maven_base_path}" ]] || makevn_die "No Maven project detected in ${repo_root}"
  boot_module="$(makevn_detect_boot_module_name "${repo_root}")"
  java_home="$(makevn_effective_java_home "${repo_root}" code "${maven_base_path}" || true)"
  [[ -n "${java_home}" ]] || makevn_die "Could not resolve code JDK. Run 'makevn doctor' or configure .makevn/config first."
  local_containers="$(makevn_effective_app_local_containers "${repo_root}" || true)"
  jar_file="$(makevn_detect_app_jar "${maven_base_path}" "${boot_module}")"
  [[ -n "${jar_file}" ]] || makevn_die "Application jar not found in ${maven_base_path}/${boot_module}/target. Run 'makevn package' first."
  jar_main_class="$(makevn_app_jar_manifest_value "${jar_file}" "Main-Class" || true)"
  jar_start_class="$(makevn_app_jar_manifest_value "${jar_file}" "Start-Class" || true)"
  health_url="$(makevn_app_health_url "${repo_root}" "${maven_base_path}")"

  log_dir="$(makevn_app_log_dir "${repo_root}")"
  mkdir -p "${log_dir}"
  log_file="${log_dir}/app.log"
  pid_file="${log_dir}/app.pid"
  jar_record="${log_dir}/app.jar"

  makevn_write_backend_metadata \
    "${MAKEVN_BACKEND_METADATA_OUT:-}" \
    "${mode}" \
    "${repo_root}" \
    "${repo_root}" \
    "${log_file}" \
    ".makevn/app/app.log" \
    "$(if [[ -n "${local_containers}" ]]; then makevn_quote_command env JAVA_HOME="${java_home}" LOCAL_CONTAINERS="${local_containers}" java -jar "${jar_file}"; else makevn_quote_command env JAVA_HOME="${java_home}" java -jar "${jar_file}"; fi)" \
    "code" \
    "${mode}"

  if [[ -f "${pid_file}" ]]; then
    existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    existing_cmd="$(ps -p "${existing_pid}" -o args= 2>/dev/null || true)"
    if [[ -n "${existing_cmd}" ]]; then
      makevn_die "Application already running with PID ${existing_pid}. Stop it first with 'makevn stop-app'."
    fi
    rm -f "${pid_file}" "${jar_record}"
  fi

  print_command_intro "${repo_root}" "${mode}"
  makevn_print_item "jar" "${jar_file}"
  if [[ -n "${jar_main_class}" ]]; then
    makevn_print_item "Main-Class" "${jar_main_class}"
  fi
  if [[ -n "${jar_start_class}" ]]; then
    makevn_print_item "Start-Class" "${jar_start_class}"
  fi
  makevn_print_item "log" "${log_file}"
  makevn_print_item "health" "${health_url}"
  if [[ -n "${local_containers}" ]]; then
    makevn_print_item "LOCAL_CONTAINERS" "${local_containers}"
  fi

  (
    cd "${repo_root}"
    {
      printf "started: %s\n" "$(date "+%Y-%m-%d %H:%M:%S")"
      printf "java_home: %s\n" "${java_home}"
      printf "jar: %s\n" "${jar_file}"
      if [[ -n "${jar_main_class}" ]]; then
        printf "main_class: %s\n" "${jar_main_class}"
      fi
      if [[ -n "${jar_start_class}" ]]; then
        printf "start_class: %s\n" "${jar_start_class}"
      fi
      if [[ -n "${local_containers}" ]]; then
        printf "LOCAL_CONTAINERS: %s\n" "${local_containers}"
        printf "command: %s\n" "$(makevn_quote_command env JAVA_HOME="${java_home}" LOCAL_CONTAINERS="${local_containers}" java -jar "${jar_file}")"
      else
        printf "command: %s\n" "$(makevn_quote_command env JAVA_HOME="${java_home}" java -jar "${jar_file}")"
      fi
      printf '\n'
    } > "${log_file}" 2>&1
    if [[ -n "${local_containers}" ]]; then
      exec env JAVA_HOME="${java_home}" PATH="${java_home}/bin:${PATH}" LOCAL_CONTAINERS="${local_containers}" java -jar "${jar_file}" >> "${log_file}" 2>&1
    fi
    exec env JAVA_HOME="${java_home}" PATH="${java_home}/bin:${PATH}" java -jar "${jar_file}" >> "${log_file}" 2>&1
  ) &
  app_pid=$!
  printf '%s\n' "${app_pid}" > "${pid_file}"
  printf '%s\n' "${jar_file}" > "${jar_record}"

  set +e
  makevn_wait_app_health "${health_url}" "${MAKEVN_APP_HEALTH_TIMEOUT:-60}" "${app_pid}" "${log_file}"
  local health_rc=$?
  set -e
  if [[ ${health_rc} -ne 0 ]]; then
    kill "${app_pid}" 2>/dev/null || true
    rm -f "${pid_file}" "${jar_record}"
    return "${health_rc}"
  fi

  makevn_print_item "pid" "${app_pid}"
  printf '%s\n' "$(makevn_accent "ok application is ready")"
}

cmd_run_app_bg() {
  local repo_root="$1"
  makevn_start_app_background "${repo_root}" run-app-bg
}

cmd_run_app() {
  local repo_root="$1"
  local pid_file=""
  local app_pid=""
  makevn_start_app_background "${repo_root}" run-app
  pid_file="$(makevn_app_log_dir "${repo_root}")/app.pid"
  app_pid="$(cat "${pid_file}" 2>/dev/null || true)"
  trap 'cmd_stop_app "'"${repo_root}"'" >/dev/null 2>&1 || true' EXIT INT TERM
  wait "${app_pid}" 2>/dev/null || true
}

cmd_stop_app() {
  local repo_root="$1"
  local log_dir=""
  local pid_file=""
  local jar_record=""
  local app_pid=""
  local app_cmd=""
  local expected_jar=""

  log_dir="$(makevn_app_log_dir "${repo_root}")"
  pid_file="${log_dir}/app.pid"
  jar_record="${log_dir}/app.jar"

  if [[ ! -f "${pid_file}" ]]; then
    print_command_intro "${repo_root}" stop-app
    printf '%s\n' "$(makevn_dim "No application PID file found.")"
    return 0
  fi

  app_pid="$(cat "${pid_file}" 2>/dev/null || true)"
  if [[ -z "${app_pid}" ]]; then
    rm -f "${pid_file}" "${jar_record}"
    return 0
  fi

  app_cmd="$(ps -p "${app_pid}" -o args= 2>/dev/null || true)"
  if [[ -z "${app_cmd}" ]]; then
    rm -f "${pid_file}" "${jar_record}"
    return 0
  fi

  expected_jar="$(cat "${jar_record}" 2>/dev/null || true)"
  [[ -n "${expected_jar}" ]] || makevn_die "Cannot safely stop PID ${app_pid}: ${jar_record} is missing."
  [[ "${app_cmd}" == *"${expected_jar}"* ]] || makevn_die "PID ${app_pid} does not match the recorded application jar: ${expected_jar}"

  print_command_intro "${repo_root}" stop-app
  kill "${app_pid}" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    if ! kill -0 "${app_pid}" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if kill -0 "${app_pid}" 2>/dev/null; then
    kill -9 "${app_pid}" 2>/dev/null || true
  fi
  rm -f "${pid_file}" "${jar_record}"
  printf '%s\n' "$(makevn_accent "ok application stopped")"
}
