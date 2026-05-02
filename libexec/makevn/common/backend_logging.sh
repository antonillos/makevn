#!/usr/bin/env bash
set -euo pipefail

makevn_metadata_escape_value() {
  local value="$1"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  printf '%s\n' "${value}"
}

makevn_write_backend_metadata() {
  local metadata_path="$1"
  local command_key="$2"
  local repo_root="$3"
  local cwd="$4"
  local log_path="$5"
  local relative_log_path="$6"
  local command_display="$7"
  local context="$8"
  local title="$9"
  local metadata_dir=""
  local tmp_metadata_path=""

  [[ -n "${metadata_path}" ]] || return 0

  metadata_dir="$(dirname "${metadata_path}")"
  mkdir -p "${metadata_dir}"
  tmp_metadata_path="$(mktemp "${metadata_path}.tmp.XXXXXX")"

  {
    printf 'command=%s\n' "$(makevn_metadata_escape_value "${command_key}")"
    printf 'repo=%s\n' "$(makevn_metadata_escape_value "${repo_root}")"
    printf 'cwd=%s\n' "$(makevn_metadata_escape_value "${cwd}")"
    printf 'log_path=%s\n' "$(makevn_metadata_escape_value "${log_path}")"
    printf 'relative_log_path=%s\n' "$(makevn_metadata_escape_value "${relative_log_path}")"
    printf 'command_display=%s\n' "$(makevn_metadata_escape_value "${command_display}")"
    printf 'title=%s\n' "$(makevn_metadata_escape_value "${title}")"
    if [[ -n "${context}" ]]; then
      printf 'context=%s\n' "$(makevn_metadata_escape_value "${context}")"
    fi
  } > "${tmp_metadata_path}"

  mv "${tmp_metadata_path}" "${metadata_path}"
}

makevn_write_quick_backend_log() {
  local repo_root="$1"
  local log_name="$2"
  local command_key="$3"
  local title="$4"
  local command_display="$5"
  local body="$6"
  local logs_dir=""
  local logfile=""
  local relative_log_path=""
  local metadata_out="${MAKEVN_BACKEND_METADATA_OUT:-}"

  logs_dir="$(makevn_logs_dir "${repo_root}")"
  mkdir -p "${logs_dir}"
  logfile="${logs_dir}/${log_name}.log"
  relative_log_path=".makevn/logs/${log_name}.log"

  {
    printf "started: %s\n" "$(date "+%Y-%m-%d %H:%M:%S")"
    printf "title: %s\n" "${title}"
    printf "command: %s\n" "${command_display}"
    printf "%s\n" "${body}"
    printf "finished: %s | exit_code: 0 | duration_seconds: 0\n" "$(date "+%Y-%m-%d %H:%M:%S")"
  } > "${logfile}"

  makevn_write_backend_metadata \
    "${metadata_out}" \
    "${command_key}" \
    "${repo_root}" \
    "${repo_root}" \
    "${logfile}" \
    "${relative_log_path}" \
    "${command_display}" \
    "" \
    "${title}"
}

makevn_frontend_owns_loader() {
  [[ "${MAKEVN_FRONTEND:-}" == "rust" && "${MAKEVN_FRONTEND_OWNS_LOADER:-}" == "1" ]]
}

makevn_quote_command() {
  local out=""
  local arg
  for arg in "$@"; do
    if [[ -n "${out}" ]]; then
      out+=" "
    fi
    out+="$(printf '%q' "${arg}")"
  done
  printf '%s\n' "${out}"
}

makevn_trace_command() {
  local label="$1"
  shift
  printf '%s %s %s\n' "$(makevn_dim '->')" "$(makevn_dim "${label}")" "$(makevn_dim "$(makevn_quote_command "$@")")"
}

makevn_format_duration() {
  local total_seconds="$1"
  local minutes=0
  local seconds=0

  if (( total_seconds < 60 )); then
    printf '%ss\n' "${total_seconds}"
    return 0
  fi

  minutes=$((total_seconds / 60))
  seconds=$((total_seconds % 60))
  printf '%sm %02ss\n' "${minutes}" "${seconds}"
}

makevn_kill_child_processes() {
  local pid="$1"
  local signal="$2"
  local child_pid

  while IFS= read -r child_pid; do
    [[ -n "${child_pid}" ]] || continue
    makevn_kill_child_processes "${child_pid}" "${signal}"
    kill "-${signal}" "${child_pid}" 2>/dev/null || kill "${child_pid}" 2>/dev/null || true
  done < <(pgrep -P "${pid}" 2>/dev/null || true)
}

makevn_interrupt_process_tree() {
  local pid="$1"

  makevn_kill_child_processes "${pid}" INT
  sleep 0.2
  if pgrep -P "${pid}" >/dev/null 2>&1; then
    makevn_kill_child_processes "${pid}" TERM
  fi
}

makevn_run_logged_in_context() {
  local repo_root="$1"
  local context="$2"
  local maven_base_path="$3"
  local log_name="$4"
  local command_key="$5"
  local title="$6"
  local java_home=""
  local logs_dir=""
  local logfile=""
  local cmd_pid=""
  local exit_code=0
  local start_epoch=0
  local end_epoch=0
  local duration_seconds=0
  local duration_display=""
  local command_exit_code=0
  local command_display=""
  local relative_log_path=""
  local metadata_out="${MAKEVN_BACKEND_METADATA_OUT:-}"
  local interrupted_by_shell=false

  shift 6

  java_home="$(makevn_effective_java_home "${repo_root}" "${context}" "${maven_base_path}" || true)"
  if [[ -z "${java_home}" ]]; then
    makevn_die "Could not resolve ${context} JDK. Run 'makevn doctor' or configure .makevn/config first."
  fi

  logs_dir="$(makevn_logs_dir "${repo_root}")"
  mkdir -p "${logs_dir}"
  logfile="${logs_dir}/${log_name}.log"
  relative_log_path=".makevn/logs/${log_name}.log"

  start_epoch="$(date +%s)"
  command_display="$(makevn_quote_command "$@")"
  makevn_write_backend_metadata \
    "${metadata_out}" \
    "${command_key}" \
    "${repo_root}" \
    "${repo_root}" \
    "${logfile}" \
    "${relative_log_path}" \
    "${command_display}" \
    "${context}" \
    "${title}"

  if ! [[ -t 1 ]]; then
    makevn_print_command_header "${title}" "" "${relative_log_path}"
    makevn_trace_command exec env JAVA_HOME="${java_home}" "$@"
    set +e
    (
      cd "${repo_root}"
      env JAVA_HOME="${java_home}" PATH="${java_home}/bin:${PATH}" "$@"
    ) 2>&1 | tee "${logfile}"
    exit_code=${PIPESTATUS[0]}
    set -e
    end_epoch="$(date +%s)"
    duration_seconds=$((end_epoch - start_epoch))
    duration_display="$(makevn_format_duration "${duration_seconds}")"
    if [[ ${exit_code} -eq 0 ]]; then
      printf '%s %s\n' "$(makevn_accent '[ok]')" "$(makevn_accent "${duration_display}")"
    else
      printf '%s %s\n' "$(makevn_warn 'fail')" "$(makevn_warn "exit ${exit_code} after ${duration_display}; check the log for details")"
    fi
    return ${exit_code}
  fi

  bash -c '
    repo_root="$1"
    java_home="$2"
    title="$3"
    start_epoch="$4"
    logfile="$5"
    command_display="$6"
    shift 6

    cd "${repo_root}" || exit 1
    {
      printf "started: %s\n" "$(date "+%Y-%m-%d %H:%M:%S")"
      printf "pid: %s\n" "$$"
      printf "title: %s\n" "${title}"
      printf "java_home: %s\n" "${java_home}"
      printf "command: %s\n" "${command_display}"
      printf "duration_started_epoch: %s\n" "${start_epoch}"
      set +e
      env JAVA_HOME="${java_home}" PATH="${java_home}/bin:${PATH}" "$@"
      command_exit_code=$?
      set -e
      printf "finished: %s | exit_code: %s | duration_seconds: %s\n" \
        "$(date "+%Y-%m-%d %H:%M:%S")" \
        "${command_exit_code}" \
        "$(( $(date +%s) - start_epoch ))"
      exit "${command_exit_code}"
    } > "${logfile}" 2>&1
  ' bash "${repo_root}" "${java_home}" "${title}" "${start_epoch}" "${logfile}" "${command_display}" "$@" &
  cmd_pid=$!

  if makevn_frontend_owns_loader; then
    local interrupted_by_frontend=false

    cleanup_frontend_loader_interrupt() {
      interrupted_by_frontend=true
      makevn_interrupt_process_tree "${cmd_pid}"

      set +e
      wait "${cmd_pid}" 2>/dev/null
      exit_code=$?
      set -e
    }

    trap 'cleanup_frontend_loader_interrupt' INT TERM
    set +e
    wait "${cmd_pid}"
    exit_code=$?
    set -e
    trap - INT TERM

    if [[ "${interrupted_by_frontend}" == true || ${exit_code} -eq 130 ]]; then
      return 130
    fi

    return ${exit_code}
  fi

  makevn_print_command_header "${title}" "${cmd_pid}" "${relative_log_path}"
  makevn_trace_command exec env JAVA_HOME="${java_home}" "$@"

  cleanup_shell_wait_interrupt() {
    interrupted_by_shell=true
    makevn_interrupt_process_tree "${cmd_pid}"
  }

  trap 'cleanup_shell_wait_interrupt' INT TERM
  set +e
  wait "${cmd_pid}"
  exit_code=$?
  set -e
  trap - INT TERM
  end_epoch="$(date +%s)"
  duration_seconds=$((end_epoch - start_epoch))
  duration_display="$(makevn_format_duration "${duration_seconds}")"

  if [[ "${interrupted_by_shell}" == true || ${exit_code} -eq 130 ]]; then
    printf '\r\033[2K%s %s\n' "$(makevn_warn 'x')" "$(makevn_warn "interrupted after ${duration_display}")"
    return 130
  fi

  if [[ ${exit_code} -eq 0 ]]; then
    printf '%s %s\n' "$(makevn_accent '[ok]')" "$(makevn_accent "${duration_display}")"
    return 0
  fi

  printf '\r\033[2K%s %s\n' "$(makevn_warn 'fail')" "$(makevn_warn "exit ${exit_code} after ${duration_display}; check the log for details")"
  return ${exit_code}
}

