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

  find "${maven_base_path}/${boot_module}/target" \
    -name "*.jar" \
    -not -name "*-sources.jar" \
    -not -name "*.original" \
    -not -name "*-tests.jar" \
    -type f \
    2>/dev/null \
    | grep -v "original" \
    | LC_ALL=C sort \
    | head -n 1
}

makevn_app_health_url() {
  local maven_base_path="$1"
  local project_key=""

  project_key="$(makevn_detect_project_key "${maven_base_path}" || true)"
  [[ -n "${project_key}" ]] || makevn_die "Could not detect com.inditex project key from ${maven_base_path}/pom.xml"
  printf 'http://localhost:8080/%s/amiga/health\n' "${project_key}"
}

makevn_wait_app_health() {
  local health_url="$1"
  local timeout_seconds="${2:-30}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if curl -fsS "${health_url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  makevn_die "App health check did not pass within ${timeout_seconds}s: ${health_url}"
}

makevn_start_app_background() {
  local repo_root="$1"
  local mode="$2"
  local maven_base_path=""
  local boot_module=""
  local java_home=""
  local jar_file=""
  local health_url=""
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
  jar_file="$(makevn_detect_app_jar "${maven_base_path}" "${boot_module}")"
  [[ -n "${jar_file}" ]] || makevn_die "Application jar not found in ${maven_base_path}/${boot_module}/target. Run 'makevn package' first."
  health_url="$(makevn_app_health_url "${maven_base_path}")"

  log_dir="$(makevn_app_log_dir "${repo_root}")"
  mkdir -p "${log_dir}"
  log_file="${log_dir}/app.log"
  pid_file="${log_dir}/app.pid"
  jar_record="${log_dir}/app.jar"

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
  makevn_print_item "log" "${log_file}"
  makevn_print_item "health" "${health_url}"

  (
    cd "${repo_root}"
    exec env JAVA_HOME="${java_home}" PATH="${java_home}/bin:${PATH}" java -jar "${jar_file}" > "${log_file}" 2>&1
  ) &
  app_pid=$!
  printf '%s\n' "${app_pid}" > "${pid_file}"
  printf '%s\n' "${jar_file}" > "${jar_record}"

  set +e
  makevn_wait_app_health "${health_url}" "${MAKEVN_APP_HEALTH_TIMEOUT:-30}"
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
