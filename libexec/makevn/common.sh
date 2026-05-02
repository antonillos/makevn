#!/usr/bin/env bash
set -euo pipefail

MAKEVN_LIBEXEC_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKEVN_INSTALL_ROOT="${MAKEVN_INSTALL_ROOT:-$(CDPATH= cd -- "${MAKEVN_LIBEXEC_DIR}/../.." && pwd)}"
MAKEVN_BIN_PATH="${MAKEVN_BIN_PATH:-${MAKEVN_INSTALL_ROOT}/bin/makevn}"
MAKEVN_VERSION="${MAKEVN_VERSION:-0.1.0-dev}"
MAKEVN_BLOCK_BEGIN="# makevn:begin"
MAKEVN_BLOCK_END="# makevn:end"

makevn_use_color() {
  [[ -t 1 ]] || [[ -t 2 ]] || return 1
  [[ "${TERM:-}" != "dumb" ]]
  [[ -z "${NO_COLOR:-}" ]]
}

makevn_style() {
  local code="$1"
  shift
  if makevn_use_color; then
    printf '\033[%sm%s\033[0m' "${code}" "$*"
  else
    printf '%s' "$*"
  fi
}

makevn_dim() {
  makevn_style "90" "$*"
}

makevn_accent() {
  makevn_style "36" "$*"
}

makevn_warn() {
  makevn_style "33" "$*"
}

makevn_print_header() {
  local title="$1"
  printf '%s %s\n' "$(makevn_dim '::')" "$(makevn_accent "${title}")"
}

makevn_print_item() {
  local label="$1"
  local value="$2"
  printf '%s %s%s\n' "$(makevn_dim '-')" "$(makevn_dim "${label}:")" " ${value}"
}

makevn_print_command_header() {
  local title="$1"
  local pid="${2:-}"
  local log_path="${3:-}"
  local line=""

  line="$(makevn_accent "makevn ${title}")"
  if [[ -n "${pid}" ]]; then
    line+=" $(makevn_dim '|') $(makevn_dim "pid: ${pid}")"
  fi
  if [[ -n "${log_path}" ]]; then
    line+=" $(makevn_dim '|') $(makevn_dim "log: ${log_path}")"
  fi

  printf '%s %s\n' "$(makevn_dim '::')" "${line}"
}

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

makevn_spinner_hint() {
  local message="$1"

  if makevn_use_color; then
    if [[ "${message}" == "again to interrupt" ]]; then
      printf '%s %s' "$(makevn_style "97" "esc")" "$(makevn_style "94" "${message}")"
      return 0
    fi

    printf '%s %s' "$(makevn_style "97" "esc")" "$(makevn_dim "${message}")"
    return 0
  fi

  printf 'esc %s' "${message}"
}

makevn_spinner_kitt_frame() {
  local frame_index="$1"
  local width=8
  local hold_frames=4
  local forward_frames=${width}
  local backward_frames=$((width - 1))
  local cycle_length=$((forward_frames + hold_frames + backward_frames + hold_frames))
  local cycle_index=$((frame_index % cycle_length))
  local active_position=0
  local moving_left=true
  local hold_progress=-1
  local pulse_codes=(60 61 62 61)
  local trail_codes=(189 153 111 68)
  local default_code="${pulse_codes[$((frame_index % ${#pulse_codes[@]}))]}"
  local out=""
  local i=0
  local directional_distance=0
  local color_code=""
  local color_index=0
  local glyph=""

  if (( cycle_index < forward_frames )); then
    active_position=$((width - 1 - cycle_index))
  elif (( cycle_index < forward_frames + hold_frames )); then
    active_position=0
    hold_progress=$((cycle_index - forward_frames))
  elif (( cycle_index < forward_frames + hold_frames + backward_frames )); then
    active_position=$((cycle_index - forward_frames - hold_frames + 1))
    moving_left=false
  else
    moving_left=false
    active_position=$((width - 1))
    hold_progress=$((cycle_index - forward_frames - hold_frames - backward_frames))
  fi

  for ((i = 0; i < width; i++)); do
    if [[ "${moving_left}" == true ]]; then
      directional_distance=$((i - active_position))
    else
      directional_distance=$((active_position - i))
    fi

    color_index=${directional_distance}
    if (( hold_progress >= 0 )); then
      color_index=$((color_index + hold_progress))
    fi

    if (( color_index >= 0 && color_index < ${#trail_codes[@]} )); then
      color_code="${trail_codes[$color_index]}"
      glyph="■"
    else
      color_code="${default_code}"
      glyph="·"
    fi

    if makevn_use_color; then
      out+="$(makevn_style "38;5;${color_code}" "${glyph}")"
    else
      out+="."
    fi
  done

  printf '%s' "${out}"
}

makevn_wait_with_spinner() {
  local pid="$1"
  local frame=0
  local hint="interrupt"
  local key=""
  local tty_state=""
  local cancel_requested=false
  local signal_requested=false
  local trap_waited=false
  local trap_exit_code=0
  local second_escape_deadline=0
  local now=0
  local exit_code=0

  MAKEVN_SPINNER_CANCEL_REQUESTED=false

  if ! [[ -t 0 && -t 1 ]]; then
    set +e
    wait "${pid}"
    exit_code=$?
    set -e
    return ${exit_code}
  fi

  tty_state="$(stty -g < /dev/tty)"
  stty -echo -icanon min 0 time 1 < /dev/tty

  cleanup_spinner_interrupt() {
    if [[ "${signal_requested}" == true ]]; then
      return 0
    fi

    cancel_requested=true
    signal_requested=true
    makevn_interrupt_process_tree "${pid}"

    set +e
    wait "${pid}" 2>/dev/null
    trap_exit_code=$?
    set -e
    trap_waited=true
  }

  trap 'cleanup_spinner_interrupt' INT TERM

  if makevn_use_color; then
    printf '\033[?25l'
  fi

  while kill -0 "${pid}" 2>/dev/null; do
    now="$(date +%s)"
    if (( second_escape_deadline > now )); then
      hint="again to interrupt"
    else
      hint="interrupt"
      second_escape_deadline=0
    fi

    printf '\r\033[2K%s  %s' \
      "$(makevn_spinner_kitt_frame "${frame}")" \
      "$(makevn_spinner_hint "${hint}")"
    frame=$((frame + 1))
    key="$(dd bs=1 count=1 2>/dev/null < /dev/tty || true)"

    if [[ "${signal_requested}" == true ]]; then
      break
    fi

    if [[ "${key}" == $'\e' ]]; then
      now="$(date +%s)"
      if (( second_escape_deadline > now )); then
        cancel_requested=true
        makevn_interrupt_process_tree "${pid}"
        break
      fi
      second_escape_deadline=$((now + 3))
    fi
  done

  trap - INT TERM
  stty "${tty_state}" < /dev/tty
  printf '\r\033[2K'
  if makevn_use_color; then
    printf '\033[?25h'
  fi

  if [[ "${trap_waited}" == true ]]; then
    exit_code=${trap_exit_code}
  else
    set +e
    wait "${pid}"
    exit_code=$?
    set -e
  fi
  if [[ "${cancel_requested}" == true ]]; then
    MAKEVN_SPINNER_CANCEL_REQUESTED=true
    return 0
  fi
  return ${exit_code}
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

  MAKEVN_SPINNER_CANCEL_REQUESTED=false
  set +e
  makevn_wait_with_spinner "${cmd_pid}"
  exit_code=$?
  set -e
  if [[ "${MAKEVN_SPINNER_CANCEL_REQUESTED:-false}" == true ]]; then
    exit_code=130
  fi
  end_epoch="$(date +%s)"
  duration_seconds=$((end_epoch - start_epoch))
  duration_display="$(makevn_format_duration "${duration_seconds}")"

  if [[ "${MAKEVN_SPINNER_CANCEL_REQUESTED:-false}" == true || ${exit_code} -eq 130 ]]; then
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

makevn_die() {
  printf '%s\n' "$(makevn_warn "Error: $*")" >&2
  exit 1
}

makevn_now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

makevn_resolve_repo_root() {
  local candidate="${1:-$PWD}"
  if [[ ! -d "${candidate}" ]]; then
    makevn_die "Repository path does not exist: ${candidate}"
  fi
  (CDPATH= cd -- "${candidate}" && pwd)
}

makevn_state_dir() {
  printf '%s/.makevn\n' "$1"
}

makevn_manifest_path() {
  printf '%s/manifest\n' "$(makevn_state_dir "$1")"
}

makevn_state_json_path() {
  printf '%s/state.json\n' "$(makevn_state_dir "$1")"
}

makevn_config_path() {
  printf '%s/config\n' "$(makevn_state_dir "$1")"
}

makevn_profile_path() {
  printf '%s/profile.env\n' "$(makevn_state_dir "$1")"
}

makevn_logs_dir() {
  printf '%s/logs\n' "$(makevn_state_dir "$1")"
}

makevn_load_config() {
  local repo_root="$1"
  local config_path
  config_path="$(makevn_config_path "${repo_root}")"
  if [[ -f "${config_path}" ]]; then
    # shellcheck source=/dev/null
    source "${config_path}"
  fi
}

makevn_load_profile() {
  local repo_root="$1"
  local profile_path
  profile_path="$(makevn_profile_path "${repo_root}")"
  if [[ -f "${profile_path}" ]]; then
    # shellcheck source=/dev/null
    source "${profile_path}"
  fi
}

makevn_json_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"

  printf '%s' "${value}"
}

makevn_collect_doctor_snapshot() {
  local repo_root="$1"
  local maven_base_path=""
  local code_tool_versions=""
  local karate_tool_versions=""
  local code_java_home=""
  local karate_java_home=""
  local code_java_version_line=""
  local karate_java_version_line=""
  local run_configured="no"
  local existing_makefile="no"
  local existing_gnumakefile="no"
  local current_mode="not initialized"
  local recommended_mode=""
  local profile_path=""
  local profile_status="not generated"
  local detected_workflow_files=""
  local detected_maven_cli_flags=""
  local detected_maven_prop_flags=""
  local detected_maven_cache_source="unresolved"
  local compile_profile=""
  local build_profile=""
  local test_profile=""
  local verify_profile=""

  if [[ -d "$(makevn_state_dir "${repo_root}")" ]]; then
    makevn_refresh_profile "${repo_root}"
  fi

  makevn_detect_repo_profile "${repo_root}"
  detected_workflow_files="${MAKEVN_DETECTED_WORKFLOW_FILES:-}"
  detected_maven_cli_flags="${MAKEVN_DETECTED_MAVEN_CLI_FLAGS:-}"
  detected_maven_prop_flags="${MAKEVN_DETECTED_MAVEN_PROP_FLAGS:-}"
  detected_maven_cache_source="${MAKEVN_DETECTED_MAVEN_CACHE_SOURCE:-unresolved}"
  compile_profile="$(makevn_detected_command_profile_summary compile)"
  build_profile="$(makevn_detected_command_profile_summary build)"
  test_profile="$(makevn_detected_command_profile_summary test)"
  verify_profile="$(makevn_detected_command_profile_summary verify)"

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  code_tool_versions="$(makevn_detect_code_tool_versions "${repo_root}" "${maven_base_path}" || true)"
  karate_tool_versions="$(makevn_detect_karate_tool_versions "${repo_root}" || true)"
  code_java_home="$(makevn_effective_java_home "${repo_root}" code "${maven_base_path}" || true)"
  karate_java_home="$(makevn_effective_java_home "${repo_root}" karate "${maven_base_path}" || true)"
  recommended_mode="$(makevn_recommended_mode "${repo_root}")"

  [[ -f "${repo_root}/Makefile" ]] && existing_makefile="${repo_root}/Makefile"
  [[ -f "${repo_root}/GNUmakefile" ]] && existing_gnumakefile="${repo_root}/GNUmakefile"
  [[ -f "$(makevn_manifest_path "${repo_root}")" ]] && current_mode="$(makevn_manifest_value "${repo_root}" mode || true)"
  profile_path="$(makevn_profile_path "${repo_root}")"
  [[ -f "${profile_path}" ]] && profile_status="${profile_path}"

  makevn_load_config "${repo_root}"
  [[ -n "${MAKEVN_RUN_CMD:-}" ]] && run_configured="yes"

  if [[ -n "${code_java_home}" ]]; then
    code_java_version_line="$(makevn_java_version_line "${code_java_home}")"
  fi

  if [[ -n "${karate_java_home}" ]]; then
    karate_java_version_line="$(makevn_java_version_line "${karate_java_home}")"
  fi

  MAKEVN_DOCTOR_REPO_ROOT="${repo_root}"
  MAKEVN_DOCTOR_JAVA_MAVEN_REPO="$(if [[ -n "${maven_base_path}" ]]; then printf yes; else printf no; fi)"
  MAKEVN_DOCTOR_MAVEN_BASE_PATH="${maven_base_path:-unresolved}"
  MAKEVN_DOCTOR_EXISTING_MAKEFILE="${existing_makefile}"
  MAKEVN_DOCTOR_EXISTING_GNUMAKEFILE="${existing_gnumakefile}"
  MAKEVN_DOCTOR_EXISTING_STATE_DIR="$(if [[ -d "$(makevn_state_dir "${repo_root}")" ]]; then printf yes; else printf no; fi)"
  MAKEVN_DOCTOR_CURRENT_MODE="${current_mode}"
  MAKEVN_DOCTOR_CODE_TOOL_VERSIONS="${code_tool_versions:-unresolved}"
  MAKEVN_DOCTOR_KARATE_TOOL_VERSIONS="${karate_tool_versions:-unresolved}"
  MAKEVN_DOCTOR_DETECTED_WORKFLOW_FILES="${detected_workflow_files:-none}"
  MAKEVN_DOCTOR_DETECTED_MAVEN_CLI_FLAGS="${detected_maven_cli_flags:-none}"
  MAKEVN_DOCTOR_DETECTED_MAVEN_PROP_FLAGS="${detected_maven_prop_flags:-none}"
  MAKEVN_DOCTOR_DETECTED_MAVEN_CACHE_SOURCE="${detected_maven_cache_source}"
  MAKEVN_DOCTOR_COMPILE_PROFILE="${compile_profile}"
  MAKEVN_DOCTOR_BUILD_PROFILE="${build_profile}"
  MAKEVN_DOCTOR_TEST_PROFILE="${test_profile}"
  MAKEVN_DOCTOR_VERIFY_PROFILE="${verify_profile}"
  MAKEVN_DOCTOR_CODE_JAVA_HOME="${code_java_home:-unresolved}"
  MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE="${code_java_version_line}"
  MAKEVN_DOCTOR_KARATE_JAVA_HOME="${karate_java_home:-unresolved}"
  MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE="${karate_java_version_line}"
  MAKEVN_DOCTOR_RUN_CONFIGURED="${run_configured}"
  MAKEVN_DOCTOR_PROFILE_STATUS="${profile_status}"
  MAKEVN_DOCTOR_RECOMMENDED_MODE="${recommended_mode}"
  MAKEVN_DOCTOR_SUGGESTED_NEXT=""
  MAKEVN_DOCTOR_SUGGESTED_OPTIONAL=""
  MAKEVN_DOCTOR_SUGGESTED_NOTE=""

  case "${recommended_mode}" in
    make-include)
      MAKEVN_DOCTOR_SUGGESTED_NEXT="makevn init --mode make-include"
      MAKEVN_DOCTOR_SUGGESTED_OPTIONAL="makevn init --mode make-include --write-make-include"
      ;;
    standalone)
      MAKEVN_DOCTOR_SUGGESTED_NEXT="makevn init --mode standalone"
      MAKEVN_DOCTOR_SUGGESTED_OPTIONAL="makevn init --mode make-bootstrap"
      ;;
    make-bootstrap)
      MAKEVN_DOCTOR_SUGGESTED_NEXT="makevn init --mode make-bootstrap"
      ;;
    unsupported)
      MAKEVN_DOCTOR_SUGGESTED_NOTE="no automatic recommendation: Maven repository signals were not detected"
      MAKEVN_DOCTOR_SUGGESTED_OPTIONAL="use an explicit mode with makevn init --mode ..."
      ;;
    *)
      MAKEVN_DOCTOR_SUGGESTED_NEXT="makevn uninstall"
      ;;
  esac
}

makevn_print_doctor_json() {
  printf '{\n'
  printf '  "version": 1,\n'
  printf '  "command": "doctor",\n'
  printf '  "repository_analysis": {\n'
  printf '    "repo_root": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_REPO_ROOT}")"
  printf '    "java_maven_repo": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_JAVA_MAVEN_REPO}")"
  printf '    "maven_base_path": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_MAVEN_BASE_PATH}")"
  printf '    "existing_makefile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_EXISTING_MAKEFILE}")"
  printf '    "existing_gnumakefile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_EXISTING_GNUMAKEFILE}")"
  printf '    "existing_makevn": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_EXISTING_STATE_DIR}")"
  printf '    "current_makevn_mode": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CURRENT_MODE}")"
  printf '    "code_tool_versions": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CODE_TOOL_VERSIONS}")"
  printf '    "karate_tool_versions": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_KARATE_TOOL_VERSIONS}")"
  printf '    "detected_workflow_files": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_WORKFLOW_FILES}")"
  printf '    "detected_maven_cli_flags": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_MAVEN_CLI_FLAGS}")"
  printf '    "detected_maven_prop_flags": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_MAVEN_PROP_FLAGS}")"
  printf '    "detected_maven_cache": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_DETECTED_MAVEN_CACHE_SOURCE}")"
  printf '    "compile_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_COMPILE_PROFILE}")"
  printf '    "build_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_BUILD_PROFILE}")"
  printf '    "test_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_TEST_PROFILE}")"
  printf '    "verify_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_VERIFY_PROFILE}")"
  printf '    "resolved_code_java_home": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CODE_JAVA_HOME}")"
  printf '    "resolved_code_java_version": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE}")"
  printf '    "resolved_karate_java_home": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_KARATE_JAVA_HOME}")"
  printf '    "resolved_karate_java_version": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE}")"
  printf '    "run_command_configured": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_RUN_CONFIGURED}")"
  printf '    "persisted_profile": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_PROFILE_STATUS}")"
  printf '    "recommended_mode": "%s"\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_RECOMMENDED_MODE}")"
  printf '  },\n'
  printf '  "suggested_next_step": {\n'
  printf '    "next": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_SUGGESTED_NEXT}")"
  printf '    "optional": "%s",\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_SUGGESTED_OPTIONAL}")"
  printf '    "note": "%s"\n' "$(makevn_json_escape "${MAKEVN_DOCTOR_SUGGESTED_NOTE}")"
  printf '  }\n'
  printf '}\n'
}

makevn_has_word() {
  local list="$1"
  local word="$2"
  local item

  for item in ${list}; do
    if [[ "${item}" == "${word}" ]]; then
      return 0
    fi
  done

  return 1
}

makevn_append_word() {
  local list="$1"
  local word="$2"

  if [[ -z "${word}" ]]; then
    printf '%s\n' "${list}"
    return 0
  fi

  if makevn_has_word "${list}" "${word}"; then
    printf '%s\n' "${list}"
    return 0
  fi

  if [[ -n "${list}" ]]; then
    printf '%s %s\n' "${list}" "${word}"
    return 0
  fi

  printf '%s\n' "${word}"
}

makevn_merge_words() {
  local base="$1"
  local extra="$2"
  local word

  for word in ${extra}; do
    base="$(makevn_append_word "${base}" "${word}")"
  done

  printf '%s\n' "${base}"
}

makevn_should_drop_verify_prop_flag() {
  local token="$1"

  case "${token}" in
    -DskipTests|-DskipTests=true|-DskipTests=1|-DskipTests=yes|\
    -Dmaven.test.skip|-Dmaven.test.skip=true|-Dmaven.test.skip=1|-Dmaven.test.skip=yes|\
    -DskipIT|-DskipIT=true|-DskipIT=1|-DskipIT=yes|\
    -DskipITs|-DskipITs=true|-DskipITs=1|-DskipITs=yes|\
    -DskipITests|-DskipITests=true|-DskipITests=1|-DskipITests=yes|\
    -DskipIntegrationTests|-DskipIntegrationTests=true|-DskipIntegrationTests=1|-DskipIntegrationTests=yes|\
    -DskipFailsafeTests|-DskipFailsafeTests=true|-DskipFailsafeTests=1|-DskipFailsafeTests=yes|\
    -Dmaven.failsafe.skip|-Dmaven.failsafe.skip=true|-Dmaven.failsafe.skip=1|-Dmaven.failsafe.skip=yes)
      return 0
      ;;
  esac

  return 1
}

makevn_should_drop_maven_cache_prop_flag() {
  local token="$1"

  case "${token}" in
    -Dmaven.build.cache.enabled|-Dmaven.build.cache.enabled=*)
      return 0
      ;;
  esac

  return 1
}

makevn_command_profile_prefix() {
  case "$1" in
    compile) printf '%s\n' COMPILE ;;
    build) printf '%s\n' BUILD ;;
    test) printf '%s\n' TEST ;;
    verify) printf '%s\n' VERIFY ;;
    *) return 1 ;;
  esac
}

makevn_command_profile_path_match() {
  local command_name="$1"
  local workflow_path="$2"
  local workflow_path_lc=""

  workflow_path_lc="$(printf '%s' "${workflow_path}" | tr '[:upper:]' '[:lower:]')"

  case "${command_name}" in
    compile)
      [[ "${workflow_path_lc}" == *compile* ]]
      ;;
    build)
      [[ "${workflow_path_lc}" == *build* || "${workflow_path_lc}" == *package* ]]
      ;;
    test)
      [[ "${workflow_path_lc}" == *test* || "${workflow_path_lc}" == *unit* || "${workflow_path_lc}" == *surefire* ]]
      ;;
    verify)
      [[ "${workflow_path_lc}" == *verify* || "${workflow_path_lc}" == *integration* || "${workflow_path_lc}" == *qa* || "${workflow_path_lc}" == *pr* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

makevn_command_profile_value() {
  local command_name="$1"
  local field_name="$2"
  local prefix=""
  local var_name=""

  prefix="$(makevn_command_profile_prefix "${command_name}")" || return 1
  var_name="MAKEVN_PROFILE_${prefix}_${field_name}"
  printf '%s\n' "${!var_name:-}"
}

makevn_detected_command_profile_value() {
  local command_name="$1"
  local field_name="$2"
  local prefix=""
  local var_name=""

  prefix="$(makevn_command_profile_prefix "${command_name}")" || return 1
  var_name="MAKEVN_DETECTED_${prefix}_${field_name}"
  printf '%s\n' "${!var_name:-}"
}

makevn_detected_command_profile_summary() {
  local command_name="$1"
  local workflow_file=""
  local cli_flags=""
  local prop_flags=""
  local pre_goals=""
  local summary=""

  workflow_file="$(makevn_detected_command_profile_value "${command_name}" WORKFLOW_FILE || true)"
  cli_flags="$(makevn_detected_command_profile_value "${command_name}" CLI_FLAGS || true)"
  prop_flags="$(makevn_detected_command_profile_value "${command_name}" PROP_FLAGS || true)"
  pre_goals="$(makevn_detected_command_profile_value "${command_name}" PRE_GOALS || true)"

  if [[ -z "${workflow_file}" ]]; then
    printf '%s\n' none
    return 0
  fi

  summary="${workflow_file}"
  if [[ -n "${pre_goals}" ]]; then
    summary+=" | pre-goals: ${pre_goals}"
  fi
  if [[ -n "${cli_flags}" ]]; then
    summary+=" | cli: ${cli_flags}"
  fi
  if [[ -n "${prop_flags}" ]]; then
    summary+=" | props: ${prop_flags}"
  fi

  printf '%s\n' "${summary}"
}

makevn_set_detected_command_profile() {
  local command_name="$1"
  local workflow_file="$2"
  local cli_flags="$3"
  local prop_flags="$4"
  local pre_goals="$5"
  local score="$6"
  local prefix=""
  local var_name=""

  prefix="$(makevn_command_profile_prefix "${command_name}")" || return 1
  var_name="MAKEVN_DETECTED_${prefix}_WORKFLOW_FILE"
  printf -v "${var_name}" '%s' "${workflow_file}"
  var_name="MAKEVN_DETECTED_${prefix}_CLI_FLAGS"
  printf -v "${var_name}" '%s' "${cli_flags}"
  var_name="MAKEVN_DETECTED_${prefix}_PROP_FLAGS"
  printf -v "${var_name}" '%s' "${prop_flags}"
  var_name="MAKEVN_DETECTED_${prefix}_PRE_GOALS"
  printf -v "${var_name}" '%s' "${pre_goals}"
  var_name="MAKEVN_DETECTED_${prefix}_SCORE"
  printf -v "${var_name}" '%s' "${score}"
}

makevn_init_detected_command_profiles() {
  makevn_set_detected_command_profile compile "" "" "" "" -1
  makevn_set_detected_command_profile build "" "" "" "" -1
  makevn_set_detected_command_profile test "" "" "" "" -1
  makevn_set_detected_command_profile verify "" "" "" "" -1
}

makevn_extract_maven_invocation() {
  local line="$1"

  case "${line}" in
    *"./mvnw "*)
      printf './mvnw %s\n' "${line#*./mvnw }"
      return 0
      ;;
    *"mvnw "*)
      printf 'mvnw %s\n' "${line#*mvnw }"
      return 0
      ;;
    *"mvn "*)
      printf 'mvn %s\n' "${line#*mvn }"
      return 0
      ;;
  esac

  return 1
}

makevn_detect_command_profile_from_invocation() {
  local workflow_file="$1"
  local invocation="$2"
  local -a tokens=()
  local -a goals=()
  local -a pre_goals=()
  local cli_flags=""
  local prop_flags=""
  local token=""
  local skip_next=false
  local goal=""
  local command_name=""
  local primary_goal_count=0
  local primary_goal_index=-1
  local current_score=0
  local score=0
  local i=0
  local pre_goals_value=""

  read -r -a tokens <<< "${invocation}"
  [[ ${#tokens[@]} -gt 1 ]] || return 0

  for ((i = 1; i < ${#tokens[@]}; i++)); do
    token="${tokens[$i]}"

    if [[ "${skip_next}" == true ]]; then
      skip_next=false
      continue
    fi

    case "${token}" in
      -B|--batch-mode)
        cli_flags="$(makevn_append_word "${cli_flags}" "-B")"
        ;;
      -nsu|--no-snapshot-updates)
        cli_flags="$(makevn_append_word "${cli_flags}" "-nsu")"
        ;;
      -f|--file|-pl|--projects|-rf|--resume-from|-s|--settings|-gs|--global-settings|-t|--toolchains)
        skip_next=true
        ;;
      -D*)
        prop_flags="$(makevn_append_word "${prop_flags}" "${token}")"
        ;;
      -*)
        ;;
      *)
        goals+=("${token}")
        ;;
    esac
  done

  for ((i = 0; i < ${#goals[@]}; i++)); do
    case "${goals[$i]}" in
      compile|package|test|verify)
        goal="${goals[$i]}"
        primary_goal_index=${i}
        primary_goal_count=$((primary_goal_count + 1))
        ;;
    esac
  done

  [[ ${primary_goal_count} -eq 1 ]] || return 0

  if [[ "${goal}" == "package" ]]; then
    command_name="build"
  else
    command_name="${goal}"
  fi

  for ((i = 0; i < primary_goal_index; i++)); do
    if [[ "${command_name}" != "verify" && "${goals[$i]}" == "clean" ]]; then
      pre_goals+=("clean")
    fi
  done

  if [[ "${command_name}" == "build" ]]; then
    local filtered_prop_flags=""
    for token in ${prop_flags}; do
      if [[ "${token}" != "-DskipTests" ]]; then
        filtered_prop_flags="$(makevn_append_word "${filtered_prop_flags}" "${token}")"
      fi
    done
    prop_flags="${filtered_prop_flags}"
  elif [[ "${command_name}" == "verify" ]]; then
    local filtered_prop_flags=""
    for token in ${prop_flags}; do
      if ! makevn_should_drop_verify_prop_flag "${token}"; then
        filtered_prop_flags="$(makevn_append_word "${filtered_prop_flags}" "${token}")"
      fi
    done
    prop_flags="${filtered_prop_flags}"
  fi

  score=10
  if makevn_command_profile_path_match "${command_name}" "${workflow_file}"; then
    score=$((score + 30))
  fi
  if [[ ${#goals[@]} -eq 1 ]]; then
    score=$((score + 10))
  fi
  if [[ ${#goals[@]} -eq 2 && "${goals[0]}" == "clean" ]]; then
    score=$((score + 8))
  fi
  if [[ "${command_name}" == "build" && " ${invocation} " == *" -DskipTests "* ]]; then
    score=$((score + 5))
  fi

  current_score="$(makevn_detected_command_profile_value "${command_name}" SCORE || true)"
  [[ -n "${current_score}" ]] || current_score=-1
  if (( score <= current_score )); then
    return 0
  fi

  if [[ ${#pre_goals[@]} -gt 0 ]]; then
    pre_goals_value="${pre_goals[*]}"
  fi

  makevn_set_detected_command_profile \
    "${command_name}" \
    "${workflow_file}" \
    "${cli_flags}" \
    "${prop_flags}" \
    "${pre_goals_value}" \
    "${score}"
}

makevn_detect_maven_base_path_fresh() {
  local repo_root="$1"
  local first_pom=""

  if [[ -f "${repo_root}/pom.xml" ]]; then
    printf '%s\n' "${repo_root}"
    return 0
  fi

  if [[ -f "${repo_root}/code/pom.xml" ]]; then
    printf '%s\n' "${repo_root}/code"
    return 0
  fi

  first_pom="$(find "${repo_root}" -name pom.xml -not -path '*/target/*' -not -path '*/node_modules/*' 2>/dev/null | LC_ALL=C sort | head -n 1 || true)"
  if [[ -n "${first_pom}" ]]; then
    printf '%s\n' "$(dirname "${first_pom}")"
    return 0
  fi

  return 1
}

makevn_detect_code_tool_versions_fresh() {
  local repo_root="$1"
  local maven_base_path="$2"

  if [[ -n "${maven_base_path}" && -f "${maven_base_path}/.tool-versions" ]]; then
    printf '%s\n' "${maven_base_path}/.tool-versions"
    return 0
  fi

  if [[ -f "${repo_root}/.tool-versions" ]]; then
    printf '%s\n' "${repo_root}/.tool-versions"
    return 0
  fi

  return 1
}

makevn_detect_karate_tool_versions_fresh() {
  local repo_root="$1"

  if [[ -f "${repo_root}/e2e/karate/.tool-versions" ]]; then
    printf '%s\n' "${repo_root}/e2e/karate/.tool-versions"
    return 0
  fi

  return 1
}

makevn_detect_boot_module_name() {
  local repo_root="$1"

  if [[ -d "${repo_root}/code/boot" ]]; then
    printf '%s\n' boot
    return 0
  fi

  if [[ -d "${repo_root}/code/application" ]]; then
    printf '%s\n' application
    return 0
  fi

  if [[ -d "${repo_root}/code/app" ]]; then
    printf '%s\n' app
    return 0
  fi

  printf '%s\n' boot
}

makevn_boot_compose_file_path() {
  local repo_root="$1"
  local boot_module=""

  boot_module="$(makevn_detect_boot_module_name "${repo_root}")"
  printf '%s/code/%s/src/test/resources/compose/docker-compose.yml\n' "${repo_root}" "${boot_module}"
}

makevn_boot_compose_override_file_path() {
  local repo_root="$1"
  local boot_module=""

  boot_module="$(makevn_detect_boot_module_name "${repo_root}")"
  printf '%s/code/%s/src/test/resources/compose/docker-compose.override.yml\n' "${repo_root}" "${boot_module}"
}

makevn_detect_jacoco_module_name() {
  local maven_base_path="$1"

  if [[ -d "${maven_base_path}/jacoco-report-aggregate" ]]; then
    printf '%s\n' jacoco-report-aggregate
    return 0
  fi

  if [[ -d "${maven_base_path}/coverage-report" ]]; then
    printf '%s\n' coverage-report
    return 0
  fi

  if [[ -d "${maven_base_path}/test-coverage" ]]; then
    printf '%s\n' test-coverage
    return 0
  fi

  return 1
}

makevn_jacoco_report_dir() {
  local maven_base_path="$1"
  local jacoco_module=""

  jacoco_module="$(makevn_detect_jacoco_module_name "${maven_base_path}" || true)"
  [[ -n "${jacoco_module}" ]] || return 1
  printf '%s/%s/target/site/jacoco-aggregate\n' "${maven_base_path}" "${jacoco_module}"
}

makevn_print_jacoco_report_hint() {
  local maven_base_path="$1"
  local report_dir=""

  report_dir="$(makevn_jacoco_report_dir "${maven_base_path}" || true)"
  [[ -n "${report_dir}" ]] || return 0
  [[ -f "${report_dir}/index.html" ]] || return 0
  makevn_print_item "coverage report" "${report_dir}/index.html"
}

makevn_internal_make_script_path() {
  local script_name="$1"
  local candidate=""

  candidate="${SCRIPT_DIR}/${script_name}"
  if [[ -f "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  return 1
}

makevn_detect_parent_branch_spec() {
  local repo_root="$1"
  local current_branch=""
  local candidate=""

  current_branch="$(git -C "${repo_root}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  case "${current_branch}" in
    develop|main|HEAD)
      printf '%s\n' HEAD
      return 0
      ;;
  esac

  for candidate in origin/develop develop origin/main main origin/master master; do
    if git -C "${repo_root}" rev-parse --verify "${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}...HEAD"
      return 0
    fi
  done

  printf '%s\n' HEAD
}

makevn_detect_maven_base_path() {
  local repo_root="$1"
  makevn_load_profile "${repo_root}"

  if [[ -n "${MAKEVN_PROFILE_MAVEN_BASE_PATH:-}" && -f "${MAKEVN_PROFILE_MAVEN_BASE_PATH}/pom.xml" ]]; then
    printf '%s\n' "${MAKEVN_PROFILE_MAVEN_BASE_PATH}"
    return 0
  fi

  makevn_detect_maven_base_path_fresh "${repo_root}"
}

makevn_detect_code_tool_versions() {
  local repo_root="$1"
  local maven_base_path="$2"

  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_CODE_TOOL_VERSIONS:-}" ]]; then
    printf '%s\n' "${MAKEVN_CODE_TOOL_VERSIONS}"
    return 0
  fi

  makevn_load_profile "${repo_root}"
  if [[ -n "${MAKEVN_PROFILE_CODE_TOOL_VERSIONS:-}" && -f "${MAKEVN_PROFILE_CODE_TOOL_VERSIONS}" ]]; then
    printf '%s\n' "${MAKEVN_PROFILE_CODE_TOOL_VERSIONS}"
    return 0
  fi

  makevn_detect_code_tool_versions_fresh "${repo_root}" "${maven_base_path}"
}

makevn_detect_karate_tool_versions() {
  local repo_root="$1"

  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_KARATE_TOOL_VERSIONS:-}" ]]; then
    printf '%s\n' "${MAKEVN_KARATE_TOOL_VERSIONS}"
    return 0
  fi

  makevn_load_profile "${repo_root}"
  if [[ -n "${MAKEVN_PROFILE_KARATE_TOOL_VERSIONS:-}" && -f "${MAKEVN_PROFILE_KARATE_TOOL_VERSIONS}" ]]; then
    printf '%s\n' "${MAKEVN_PROFILE_KARATE_TOOL_VERSIONS}"
    return 0
  fi

  makevn_detect_karate_tool_versions_fresh "${repo_root}"
}

makevn_detect_workflow_maven_flags() {
  local repo_root="$1"
  local workflow_root="${repo_root}/.github/workflows"
  local workflow_path=""
  local relative_path=""
  local line=""
  local invocation=""

  MAKEVN_DETECTED_WORKFLOW_FILES=""
  MAKEVN_DETECTED_MAVEN_CLI_FLAGS=""
  MAKEVN_DETECTED_MAVEN_PROP_FLAGS=""
  makevn_init_detected_command_profiles

  [[ -d "${workflow_root}" ]] || return 0

  while IFS= read -r workflow_path; do
    relative_path="${workflow_path#${repo_root}/}"
    MAKEVN_DETECTED_WORKFLOW_FILES="$(makevn_append_word "${MAKEVN_DETECTED_WORKFLOW_FILES}" "${relative_path}")"

    while IFS= read -r line; do
      case "${line}" in
        *"mvn "*|*"./mvnw "*|*"mvnw "*)
          invocation="$(makevn_extract_maven_invocation "${line}" || true)"
          if [[ "${line}" == *" -B"* || "${line}" == *" --batch-mode"* ]]; then
            MAKEVN_DETECTED_MAVEN_CLI_FLAGS="$(makevn_append_word "${MAKEVN_DETECTED_MAVEN_CLI_FLAGS}" "-B")"
          fi

          if [[ "${line}" == *" -nsu"* || "${line}" == *" --no-snapshot-updates"* ]]; then
            MAKEVN_DETECTED_MAVEN_CLI_FLAGS="$(makevn_append_word "${MAKEVN_DETECTED_MAVEN_CLI_FLAGS}" "-nsu")"
          fi

          if [[ -n "${invocation}" ]]; then
            makevn_detect_command_profile_from_invocation "${relative_path}" "${invocation}"
          fi
          ;;
      esac
    done < "${workflow_path}"
  done < <(find "${workflow_root}" -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)
}

makevn_detect_maven_cache_from_repo() {
  local maven_base_path="$1"
  local pom_path=""

  [[ -n "${maven_base_path}" ]] || return 1

  if [[ -f "${maven_base_path}/.mvn/extensions.xml" ]] && grep -Eq 'maven-build-cache-extension|maven-build-cache' "${maven_base_path}/.mvn/extensions.xml"; then
    return 0
  fi

  if [[ -f "${maven_base_path}/.mvn/maven.config" ]] && grep -Eq 'maven\.build\.cache\.enabled=true' "${maven_base_path}/.mvn/maven.config"; then
    return 0
  fi

  while IFS= read -r pom_path; do
    if grep -Eq 'maven-build-cache-extension|maven\.build\.cache\.enabled' "${pom_path}"; then
      return 0
    fi
  done < <(find "${maven_base_path}" -name pom.xml -not -path '*/target/*' -not -path '*/node_modules/*' 2>/dev/null | LC_ALL=C sort)

  return 1
}

makevn_detect_testcontainers_from_repo() {
  local maven_base_path="$1"
  local pom_path=""

  [[ -n "${maven_base_path}" ]] || return 1

  while IFS= read -r pom_path; do
    if grep -Eq '<groupId>org\.testcontainers</groupId>' "${pom_path}"; then
      return 0
    fi
  done < <(find "${maven_base_path}" -name pom.xml -not -path '*/target/*' -not -path '*/node_modules/*' 2>/dev/null | LC_ALL=C sort)

  return 1
}

makevn_detect_repo_profile() {
  local repo_root="$1"
  local maven_base_path=""
  local code_tool_versions=""
  local karate_tool_versions=""
  local maven_prop_flags=""

  maven_base_path="$(makevn_detect_maven_base_path_fresh "${repo_root}" || true)"
  code_tool_versions="$(makevn_detect_code_tool_versions_fresh "${repo_root}" "${maven_base_path}" || true)"
  karate_tool_versions="$(makevn_detect_karate_tool_versions_fresh "${repo_root}" || true)"

  makevn_detect_workflow_maven_flags "${repo_root}"
  maven_prop_flags=""

  if makevn_detect_maven_cache_from_repo "${maven_base_path}"; then
    maven_prop_flags="$(makevn_append_word "${maven_prop_flags}" "-Dmaven.build.cache.enabled=true")"
    MAKEVN_DETECTED_MAVEN_CACHE_SOURCE="pom"
  else
    MAKEVN_DETECTED_MAVEN_CACHE_SOURCE="unresolved"
  fi

  if makevn_detect_testcontainers_from_repo "${maven_base_path}"; then
    MAKEVN_DETECTED_VERIFY_IT_LOCAL_CONTAINERS="TRUE"
  else
    MAKEVN_DETECTED_VERIFY_IT_LOCAL_CONTAINERS=""
  fi

  MAKEVN_DETECTED_MAVEN_BASE_PATH="${maven_base_path}"
  MAKEVN_DETECTED_CODE_TOOL_VERSIONS="${code_tool_versions}"
  MAKEVN_DETECTED_KARATE_TOOL_VERSIONS="${karate_tool_versions}"
  MAKEVN_DETECTED_MAVEN_PROP_FLAGS="${maven_prop_flags}"
}

makevn_write_profile() {
  local repo_root="$1"
  local profile_path

  makevn_detect_repo_profile "${repo_root}"
  profile_path="$(makevn_profile_path "${repo_root}")"

  {
    printf '# makevn detected repository profile\n'
    printf '# Refresh with `makevn doctor` or `makevn init --force`.\n'
    printf 'MAKEVN_PROFILE_GENERATED_AT=%q\n' "$(makevn_now_utc)"
    printf 'MAKEVN_PROFILE_MAVEN_BASE_PATH=%q\n' "${MAKEVN_DETECTED_MAVEN_BASE_PATH}"
    printf 'MAKEVN_PROFILE_CODE_TOOL_VERSIONS=%q\n' "${MAKEVN_DETECTED_CODE_TOOL_VERSIONS}"
    printf 'MAKEVN_PROFILE_KARATE_TOOL_VERSIONS=%q\n' "${MAKEVN_DETECTED_KARATE_TOOL_VERSIONS}"
    printf 'MAKEVN_PROFILE_WORKFLOW_FILES=%q\n' "${MAKEVN_DETECTED_WORKFLOW_FILES}"
    printf 'MAKEVN_PROFILE_MAVEN_CLI_FLAGS=%q\n' "${MAKEVN_DETECTED_MAVEN_CLI_FLAGS}"
    printf 'MAKEVN_PROFILE_MAVEN_PROP_FLAGS=%q\n' "${MAKEVN_DETECTED_MAVEN_PROP_FLAGS}"
    printf 'MAKEVN_PROFILE_MAVEN_CACHE_SOURCE=%q\n' "${MAKEVN_DETECTED_MAVEN_CACHE_SOURCE}"
    printf 'MAKEVN_PROFILE_COMPILE_WORKFLOW_FILE=%q\n' "${MAKEVN_DETECTED_COMPILE_WORKFLOW_FILE:-}"
    printf 'MAKEVN_PROFILE_COMPILE_CLI_FLAGS=%q\n' "${MAKEVN_DETECTED_COMPILE_CLI_FLAGS:-}"
    printf 'MAKEVN_PROFILE_COMPILE_PROP_FLAGS=%q\n' "${MAKEVN_DETECTED_COMPILE_PROP_FLAGS:-}"
    printf 'MAKEVN_PROFILE_COMPILE_PRE_GOALS=%q\n' "${MAKEVN_DETECTED_COMPILE_PRE_GOALS:-}"
    printf 'MAKEVN_PROFILE_BUILD_WORKFLOW_FILE=%q\n' "${MAKEVN_DETECTED_BUILD_WORKFLOW_FILE:-}"
    printf 'MAKEVN_PROFILE_BUILD_CLI_FLAGS=%q\n' "${MAKEVN_DETECTED_BUILD_CLI_FLAGS:-}"
    printf 'MAKEVN_PROFILE_BUILD_PROP_FLAGS=%q\n' "${MAKEVN_DETECTED_BUILD_PROP_FLAGS:-}"
    printf 'MAKEVN_PROFILE_BUILD_PRE_GOALS=%q\n' "${MAKEVN_DETECTED_BUILD_PRE_GOALS:-}"
    printf 'MAKEVN_PROFILE_TEST_WORKFLOW_FILE=%q\n' "${MAKEVN_DETECTED_TEST_WORKFLOW_FILE:-}"
    printf 'MAKEVN_PROFILE_TEST_CLI_FLAGS=%q\n' "${MAKEVN_DETECTED_TEST_CLI_FLAGS:-}"
    printf 'MAKEVN_PROFILE_TEST_PROP_FLAGS=%q\n' "${MAKEVN_DETECTED_TEST_PROP_FLAGS:-}"
    printf 'MAKEVN_PROFILE_TEST_PRE_GOALS=%q\n' "${MAKEVN_DETECTED_TEST_PRE_GOALS:-}"
    printf 'MAKEVN_PROFILE_VERIFY_WORKFLOW_FILE=%q\n' "${MAKEVN_DETECTED_VERIFY_WORKFLOW_FILE:-}"
    printf 'MAKEVN_PROFILE_VERIFY_CLI_FLAGS=%q\n' "${MAKEVN_DETECTED_VERIFY_CLI_FLAGS:-}"
    printf 'MAKEVN_PROFILE_VERIFY_PROP_FLAGS=%q\n' "${MAKEVN_DETECTED_VERIFY_PROP_FLAGS:-}"
    printf 'MAKEVN_PROFILE_VERIFY_PRE_GOALS=%q\n' "${MAKEVN_DETECTED_VERIFY_PRE_GOALS:-}"
    printf 'MAKEVN_PROFILE_VERIFY_IT_LOCAL_CONTAINERS=%q\n' "${MAKEVN_DETECTED_VERIFY_IT_LOCAL_CONTAINERS:-}"
  } > "${profile_path}"
}

makevn_refresh_profile() {
  local repo_root="$1"
  mkdir -p "$(makevn_state_dir "${repo_root}")"
  makevn_write_profile "${repo_root}"
}

makevn_jdk_manager_script() {
  if [[ -f "${MAKEVN_LIBEXEC_DIR}/jdk_manager.sh" ]]; then
    printf '%s\n' "${MAKEVN_LIBEXEC_DIR}/jdk_manager.sh"
    return 0
  fi

  makevn_die "JDK manager script not found"
}

makevn_resolve_tool_versions_home() {
  local tool_versions_file="$1"
  local jdk_manager
  jdk_manager="$(makevn_jdk_manager_script)"
  bash "${jdk_manager}" resolve-tool-versions "${tool_versions_file}" 2>/dev/null
}

makevn_effective_java_home() {
  local repo_root="$1"
  local context="$2"
  local maven_base_path="$3"
  local tool_versions_file=""

  makevn_load_config "${repo_root}"

  if [[ "${context}" == "code" && -n "${MAKEVN_CODE_JAVA_HOME:-}" ]]; then
    printf '%s\n' "${MAKEVN_CODE_JAVA_HOME}"
    return 0
  fi

  if [[ "${context}" == "karate" && -n "${MAKEVN_KARATE_JAVA_HOME:-}" ]]; then
    printf '%s\n' "${MAKEVN_KARATE_JAVA_HOME}"
    return 0
  fi

  if [[ -n "${MAKEVN_JAVA_HOME:-}" ]]; then
    printf '%s\n' "${MAKEVN_JAVA_HOME}"
    return 0
  fi

  if [[ "${context}" == "karate" ]]; then
    tool_versions_file="$(makevn_detect_karate_tool_versions "${repo_root}" || true)"
  else
    tool_versions_file="$(makevn_detect_code_tool_versions "${repo_root}" "${maven_base_path}" || true)"
  fi

  if [[ -n "${tool_versions_file}" ]]; then
    makevn_resolve_tool_versions_home "${tool_versions_file}"
    return 0
  fi

  return 1
}

makevn_java_version_line() {
  local java_home="$1"
  "${java_home}/bin/java" -version 2>&1 | sed -n '1p'
}

makevn_maven_executable() {
  local repo_root="$1"
  local maven_base_path="$2"

  if [[ -x "${repo_root}/mvnw" ]]; then
    printf '%s\n' "${repo_root}/mvnw"
    return 0
  fi

  if [[ -n "${maven_base_path}" && -x "${maven_base_path}/mvnw" ]]; then
    printf '%s\n' "${maven_base_path}/mvnw"
    return 0
  fi

  printf '%s\n' mvn
}

makevn_run_in_context() {
  local repo_root="$1"
  local context="$2"
  local maven_base_path="$3"
  local java_home=""

  shift 3

  java_home="$(makevn_effective_java_home "${repo_root}" "${context}" "${maven_base_path}" || true)"
  if [[ -z "${java_home}" ]]; then
    makevn_die "Could not resolve ${context} JDK. Run 'makevn doctor' or configure .makevn/config first."
  fi

  makevn_trace_command exec env JAVA_HOME="${java_home}" "$@"

  (
    cd "${repo_root}"
    env JAVA_HOME="${java_home}" PATH="${java_home}/bin:${PATH}" "$@"
  )
}

makevn_maven_cli_flags_for_command() {
  local repo_root="$1"
  local command_name="$2"
  local maven_cli_flags_value=""
  local command_cli_flags_value=""

  makevn_load_profile "${repo_root}"
  maven_cli_flags_value="${MAKEVN_PROFILE_MAVEN_CLI_FLAGS:-}"
  if [[ -n "${command_name}" ]]; then
    command_cli_flags_value="$(makevn_command_profile_value "${command_name}" CLI_FLAGS || true)"
  fi

  printf '%s\n' "$(makevn_merge_words "${maven_cli_flags_value}" "${command_cli_flags_value}")"
}

makevn_maven_prop_flags_for_command() {
  local repo_root="$1"
  local command_name="$2"
  local maven_prop_flags_value=""
  local command_prop_flags_value=""

  makevn_load_profile "${repo_root}"
  maven_prop_flags_value="${MAKEVN_PROFILE_MAVEN_PROP_FLAGS:-}"
  if [[ -n "${command_name}" ]]; then
    command_prop_flags_value="$(makevn_command_profile_value "${command_name}" PROP_FLAGS || true)"
  fi

  printf '%s\n' "$(makevn_merge_words "${maven_prop_flags_value}" "${command_prop_flags_value}")"
}

makevn_maven_pre_goals_for_command() {
  local repo_root="$1"
  local command_name="$2"

  makevn_load_profile "${repo_root}"
  if [[ -n "${command_name}" ]]; then
    printf '%s\n' "$(makevn_command_profile_value "${command_name}" PRE_GOALS || true)"
    return 0
  fi

  printf '\n'
}

makevn_trim() {
  printf '%s\n' "$(printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
}

makevn_test_log_token() {
  local token=""

  token="$(printf '%s' "$1" | tr '/ :,=' '_____' | tr -cd '[:alnum:]._-')"
  if [[ -n "${token}" ]]; then
    printf '%s\n' "${token}"
    return 0
  fi

  printf '%s\n' test
}

makevn_run_selected_test() {
  local repo_root="$1"
  local test_name="$2"
  local fast_mode="$3"
  local maven_base_path=""
  local maven_executable=""
  local test_file=""
  local relative_test_file=""
  local module_path=""
  local package_name=""
  local full_test_class=""
  local boot_module=""
  local local_containers="${LOCAL_CONTAINERS:-TRUE}"
  local cli_flags_value=""
  local prop_flags_value=""
  local log_name=""
  local title=""
  local test_param=""
  local test_mode="unit"
  local -a cli_flags=()
  local -a prop_flags=()
  local -a maven_args=()

  shift 3

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if [[ -z "${maven_base_path}" ]]; then
    printf '%s\n' "$(makevn_warn "Error: No Maven project detected in ${repo_root}")" >&2
    return 1
  fi

  test_file="$(find "${maven_base_path}" -path '*/src/test/java/*' -name "${test_name}.java" -type f | LC_ALL=C sort | head -n 1 || true)"
  if [[ -z "${test_file}" ]]; then
    printf '%s\n' "$(makevn_warn "Error: test file not found: ${test_name}.java")" >&2
    return 1
  fi

  relative_test_file="${test_file#${maven_base_path}/}"
  if [[ "${relative_test_file}" != */src/* ]]; then
    printf '%s\n' "$(makevn_warn "Error: could not detect module path for ${test_name}")" >&2
    return 1
  fi

  module_path="${relative_test_file%%/src/*}"
  package_name="$(sed -nE 's/^[[:space:]]*package[[:space:]]+([^;]+);[[:space:]]*$/\1/p' "${test_file}" | head -n 1)"
  if [[ -z "${package_name}" ]]; then
    printf '%s\n' "$(makevn_warn "Error: could not extract package from ${test_file}")" >&2
    return 1
  fi

  full_test_class="${package_name}.${test_name}"
  if [[ "${test_name}" == *IT ]] || grep -Eq '@SpringBootTest|@DataMongoTest|@WebMvcTest|@Testcontainers' "${test_file}"; then
    test_mode="integration"
    test_param="-Dit.test=${full_test_class}"
  else
    test_param="-Dtest=${full_test_class}"
  fi

  maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
  cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" test)"
  cli_flags_value="$(makevn_append_word "${cli_flags_value}" "-nsu")"
  prop_flags_value="$(makevn_maven_prop_flags_for_command "${repo_root}" test)"
  prop_flags_value="$(makevn_append_word "${prop_flags_value}" "-Damiga-javaformat.skip=true")"
  prop_flags_value="$(makevn_append_word "${prop_flags_value}" "${test_param}")"
  prop_flags_value="$(makevn_append_word "${prop_flags_value}" "-Dfailsafe.failIfNoSpecifiedTests=false")"
  prop_flags_value="$(makevn_append_word "${prop_flags_value}" "-Dsurefire.failIfNoSpecifiedTests=false")"
  prop_flags_value="$(makevn_append_word "${prop_flags_value}" "-Dmaven.build.cache.enabled=true")"

  if [[ "${test_mode}" == "integration" ]]; then
    boot_module="$(makevn_detect_boot_module_name "${repo_root}")"
    if [[ "${fast_mode}" == "true" ]]; then
      if [[ ! -d "${maven_base_path}/${boot_module}/target/classes" ]]; then
        printf '%s\n' "$(makevn_warn "Error: boot module not compiled (${boot_module}). Run 'makevn test --name ${test_name}' first.")" >&2
        return 1
      fi
      if [[ ! -d "${maven_base_path}/${module_path}/target/test-classes" ]]; then
        printf '%s\n' "$(makevn_warn "Error: test classes not compiled for ${module_path}. Run 'makevn test --name ${test_name}' first.")" >&2
        return 1
      fi
      title="test ${test_name} --fast"
      log_name="test-fast-$(makevn_test_log_token "${test_name}")"
      maven_args=(env "LOCAL_CONTAINERS=${local_containers}" "${maven_executable}")
      if [[ -n "${cli_flags_value}" ]]; then
        read -r -a cli_flags <<< "${cli_flags_value}"
        maven_args+=("${cli_flags[@]}")
      fi
      maven_args+=(-f "${maven_base_path}/pom.xml" -pl "${module_path}" -am failsafe:integration-test failsafe:verify)
    else
      title="test ${test_name}"
      log_name="test-$(makevn_test_log_token "${test_name}")"
      maven_args=(env "LOCAL_CONTAINERS=${local_containers}" "${maven_executable}")
      if [[ -n "${cli_flags_value}" ]]; then
        read -r -a cli_flags <<< "${cli_flags_value}"
        maven_args+=("${cli_flags[@]}")
      fi
      maven_args+=(-f "${maven_base_path}/pom.xml" -pl "${module_path}" -am test-compile failsafe:integration-test failsafe:verify)
    fi
  else
    if [[ "${fast_mode}" == "true" ]]; then
      if [[ ! -d "${maven_base_path}/${module_path}/target/test-classes" ]]; then
        printf '%s\n' "$(makevn_warn "Error: test classes not compiled for ${module_path}. Run 'makevn test --name ${test_name}' first.")" >&2
        return 1
      fi
      title="test ${test_name} --fast"
      log_name="test-fast-$(makevn_test_log_token "${test_name}")"
    else
      title="test ${test_name}"
      log_name="test-$(makevn_test_log_token "${test_name}")"
    fi

    maven_args=("${maven_executable}")
    if [[ -n "${cli_flags_value}" ]]; then
      read -r -a cli_flags <<< "${cli_flags_value}"
      maven_args+=("${cli_flags[@]}")
    fi
    maven_args+=(-f "${maven_base_path}/pom.xml" -pl "${module_path}" -am)
    if [[ "${fast_mode}" == "true" ]]; then
      maven_args+=(surefire:test)
    else
      maven_args+=(test)
    fi
    prop_flags_value="$(makevn_append_word "${prop_flags_value}" "-Dsurefire.testFailureIgnore=false")"
  fi

  if [[ -n "${prop_flags_value}" ]]; then
    read -r -a prop_flags <<< "${prop_flags_value}"
    maven_args+=("${prop_flags[@]}")
  fi
  if [[ $# -gt 0 ]]; then
    maven_args+=("$@")
  fi

  makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" "${log_name}" test "${title}" "${maven_args[@]}"
}

makevn_detect_verify_it_workflow_invocation() {
  local repo_root="$1"
  local workflows_root="${repo_root}/.github/workflows"
  local workflow_path=""
  local invocation=""
  local line=""
  local token=""
  local has_it_skip=false

  [[ -d "${workflows_root}" ]] || return 1

  while IFS= read -r workflow_path; do
    while IFS= read -r line; do
      invocation="$(makevn_extract_maven_invocation "${line}" || true)"
      [[ -n "${invocation}" ]] || continue
      [[ " ${invocation} " == *" install "* || " ${invocation} " == *" verify "* ]] || continue
      [[ " ${invocation} " == *" -DskipUTs "* || " ${invocation} " == *" -Dskip.unit.tests=true "* ]] || continue

      has_it_skip=false
      for token in ${invocation}; do
        if makevn_should_drop_verify_prop_flag "${token}"; then
          has_it_skip=true
          break
        fi
      done

      if [[ "${has_it_skip}" == false ]]; then
        printf '%s\n' "${invocation}"
        return 0
      fi
    done < "${workflow_path}"
  done < <(find "${workflows_root}" -type f \( -name '*integration*.yml' -o -name '*integration*.yaml' \) | LC_ALL=C sort)

  return 1
}

makevn_run_verify_it_goal() {
  local repo_root="$1"
  local log_name="$2"
  local maven_base_path=""
  local maven_executable=""
  local workflow_invocation=""
  local maven_cli_flags_value=""
  local maven_prop_flags_value=""
  local filtered_prop_flags_value=""
  local token=""
  local skip_next=false
  local local_containers=""
  local -a workflow_tokens=()
  local -a maven_cli_flags=()
  local -a filtered_prop_flags=()
  local -a maven_args=()

  shift 2

  makevn_load_profile "${repo_root}"
  local_containers="${LOCAL_CONTAINERS:-${MAKEVN_PROFILE_VERIFY_IT_LOCAL_CONTAINERS:-}}"

  workflow_invocation="$(makevn_detect_verify_it_workflow_invocation "${repo_root}" || true)"
  if [[ -n "${workflow_invocation}" ]]; then
    maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
    if [[ -z "${maven_base_path}" ]]; then
      makevn_die "No Maven project detected in ${repo_root}"
    fi

    maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
    read -r -a workflow_tokens <<< "${workflow_invocation}"

    if [[ -n "${local_containers}" ]]; then
      maven_args=(env "LOCAL_CONTAINERS=${local_containers}" "${maven_executable}" -f "${maven_base_path}/pom.xml")
    else
      maven_args=("${maven_executable}" -f "${maven_base_path}/pom.xml")
    fi
    for token in "${workflow_tokens[@]:1}"; do
      if [[ "${skip_next}" == true ]]; then
        skip_next=false
        continue
      fi

      case "${token}" in
        -f|--file)
          skip_next=true
          ;;
        -DskipIT|-DskipIT=*|-DskipITs|-DskipITs=*|-DskipITests|-DskipITests=*|-DskipIntegrationTests|-DskipIntegrationTests=*|-DskipFailsafeTests|-DskipFailsafeTests=*|-Dmaven.failsafe.skip|-Dmaven.failsafe.skip=*|-Dmaven.build.cache.enabled|-Dmaven.build.cache.enabled=*)
          ;;
        install)
          maven_args+=(verify)
          ;;
        *)
          maven_args+=("${token}")
          ;;
      esac
    done
    maven_args+=(-Dmaven.build.cache.enabled=false)
    if [[ $# -gt 0 ]]; then
      maven_args+=("$@")
    fi

    makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" "${log_name}" verify-it "${log_name}" "${maven_args[@]}"
    return 0
  fi

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if [[ -z "${maven_base_path}" ]]; then
    makevn_die "No Maven project detected in ${repo_root}"
  fi

  maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
  maven_cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" verify)"
  maven_prop_flags_value="$(makevn_maven_prop_flags_for_command "${repo_root}" verify)"

  for token in ${maven_prop_flags_value}; do
    if ! makevn_should_drop_maven_cache_prop_flag "${token}"; then
      filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "${token}")"
    fi
  done

  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-Djacoco.skip=false")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-Damiga.jacoco")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-DskipUTs")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-Dskip.unit.tests=true")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-DfailIfNoTests=false")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-Dmaven.test.failure.ignore=false")"
  filtered_prop_flags_value="$(makevn_append_word "${filtered_prop_flags_value}" "-Dmaven.build.cache.enabled=false")"

  if [[ -n "${local_containers}" ]]; then
    maven_args=(env "LOCAL_CONTAINERS=${local_containers}" "${maven_executable}")
  else
    maven_args=("${maven_executable}")
  fi
  if [[ -n "${maven_cli_flags_value}" ]]; then
    read -r -a maven_cli_flags <<< "${maven_cli_flags_value}"
    maven_args+=("${maven_cli_flags[@]}")
  fi
  maven_args+=(-f "${maven_base_path}/pom.xml" verify)
  if [[ -n "${filtered_prop_flags_value}" ]]; then
    read -r -a filtered_prop_flags <<< "${filtered_prop_flags_value}"
    maven_args+=("${filtered_prop_flags[@]}")
  fi
  if [[ $# -gt 0 ]]; then
    maven_args+=("$@")
  fi

  makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" "${log_name}" verify-it "${log_name}" "${maven_args[@]}"
}

makevn_run_maven_goal() {
  local repo_root="$1"
  local goal="$2"
  local log_name="$3"
  local command_name="$4"
  local maven_base_path
  local maven_executable
  local maven_cli_flags_value=""
  local maven_prop_flags_value=""
  local command_cli_flags_value=""
  local command_prop_flags_value=""
  local command_pre_goals_value=""
  local maven_cli_flags=()
  local maven_prop_flags=()
  local command_pre_goals=()
  local maven_args=()

  shift 4

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if [[ -z "${maven_base_path}" ]]; then
    makevn_die "No Maven project detected in ${repo_root}"
  fi

  maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
  maven_cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" "${command_name}")"
  maven_prop_flags_value="$(makevn_maven_prop_flags_for_command "${repo_root}" "${command_name}")"
  command_pre_goals_value="$(makevn_maven_pre_goals_for_command "${repo_root}" "${command_name}")"
  if [[ -n "${maven_cli_flags_value}" ]]; then
    read -r -a maven_cli_flags <<< "${maven_cli_flags_value}"
  fi
  if [[ -n "${maven_prop_flags_value}" ]]; then
    read -r -a maven_prop_flags <<< "${maven_prop_flags_value}"
  fi
  if [[ -n "${command_pre_goals_value}" ]]; then
    read -r -a command_pre_goals <<< "${command_pre_goals_value}"
  fi

  maven_args=("${maven_executable}")
  if [[ ${#maven_cli_flags[@]} -gt 0 ]]; then
    maven_args+=("${maven_cli_flags[@]}")
  fi
  maven_args+=(-f "${maven_base_path}/pom.xml")
  if [[ ${#command_pre_goals[@]} -gt 0 ]]; then
    maven_args+=("${command_pre_goals[@]}")
  fi
  maven_args+=("${goal}")
  if [[ ${#maven_prop_flags[@]} -gt 0 ]]; then
    maven_args+=("${maven_prop_flags[@]}")
  fi
  if [[ $# -gt 0 ]]; then
    maven_args+=("$@")
  fi

  makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" "${log_name}" "${command_name}" "${log_name}" "${maven_args[@]}"
}

makevn_existing_makefile_path() {
  local repo_root="$1"
  if [[ -f "${repo_root}/Makefile" ]]; then
    printf '%s\n' "${repo_root}/Makefile"
    return 0
  fi
  if [[ -f "${repo_root}/GNUmakefile" ]]; then
    printf '%s\n' "${repo_root}/GNUmakefile"
    return 0
  fi
  return 1
}

makevn_existing_makefiles_count() {
  local repo_root="$1"
  local count=0
  [[ -f "${repo_root}/Makefile" ]] && count=$((count + 1))
  [[ -f "${repo_root}/GNUmakefile" ]] && count=$((count + 1))
  printf '%s\n' "${count}"
}

makevn_single_existing_makefile_path() {
  local repo_root="$1"
  local count

  count="$(makevn_existing_makefiles_count "${repo_root}")"
  if [[ "${count}" -eq 0 ]]; then
    makevn_die "No Makefile or GNUmakefile exists in ${repo_root}"
  fi

  if [[ "${count}" -gt 1 ]]; then
    makevn_die "Both Makefile and GNUmakefile exist. Add the include manually to avoid ambiguity."
  fi

  makevn_existing_makefile_path "${repo_root}"
}

makevn_manifest_value() {
  local repo_root="$1"
  local key="$2"
  local manifest_path

  manifest_path="$(makevn_manifest_path "${repo_root}")"
  [[ -f "${manifest_path}" ]] || return 1
  awk -F= -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "${manifest_path}"
}

makevn_recommended_mode() {
  local repo_root="$1"
  local maven_base_path=""

  if [[ -f "$(makevn_manifest_path "${repo_root}")" ]]; then
    printf '%s\n' "$(makevn_manifest_value "${repo_root}" mode || true)"
    return 0
  fi

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  if [[ -z "${maven_base_path}" ]]; then
    printf '%s\n' unsupported
    return 0
  fi

  if [[ -f "${repo_root}/Makefile" || -f "${repo_root}/GNUmakefile" ]]; then
    printf '%s\n' make-include
    return 0
  fi

  printf '%s\n' standalone
}

makevn_render_make_include() {
  local bin_path="$1"
  local template_path="${MAKEVN_INSTALL_ROOT}/share/makevn/makevn.mk"

  if [[ ! -f "${template_path}" ]]; then
    makevn_die "Make include template not found: ${template_path}"
  fi

  printf 'MAKEVN_BIN ?= %s\n' "${bin_path}"
  awk 'NR > 1 { print }' "${template_path}"
}

makevn_write_config() {
  local repo_root="$1"
  local config_path
  config_path="$(makevn_config_path "${repo_root}")"
  cat > "${config_path}" <<'EOF'
# makevn local configuration
MAKEVN_JAVA_HOME=""
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF
}

makevn_write_state_json() {
  local repo_root="$1"
  local mode="$2"
  local managed_makefile="$3"
  local generated_root_makefile="$4"
  local state_path

  state_path="$(makevn_state_json_path "${repo_root}")"
  cat > "${state_path}" <<EOF
{
  "version": 1,
  "mode": "${mode}",
  "repo_root": "${repo_root}",
  "managed_makefile": "${managed_makefile}",
  "generated_root_makefile": "${generated_root_makefile}",
  "generated_at": "$(makevn_now_utc)"
}
EOF
}

makevn_write_manifest() {
  local repo_root="$1"
  local mode="$2"
  local managed_makefile="$3"
  local generated_root_makefile="$4"
  local manifest_path

  manifest_path="$(makevn_manifest_path "${repo_root}")"
  cat > "${manifest_path}" <<EOF
mode=${mode}
managed_makefile=${managed_makefile}
generated_root_makefile=${generated_root_makefile}
generated_at=$(makevn_now_utc)
EOF
}

makevn_insert_include_block() {
  local makefile_path="$1"

  if grep -Fq "${MAKEVN_BLOCK_BEGIN}" "${makefile_path}"; then
    return 0
  fi

  cat >> "${makefile_path}" <<EOF

${MAKEVN_BLOCK_BEGIN}
include .makevn/makevn.mk
${MAKEVN_BLOCK_END}
EOF
}

makevn_remove_include_block() {
  local makefile_path="$1"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v begin="${MAKEVN_BLOCK_BEGIN}" -v end="${MAKEVN_BLOCK_END}" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "${makefile_path}" > "${tmp_file}"
  mv "${tmp_file}" "${makefile_path}"
}

makevn_bootstrap_makefile_content() {
  cat <<'EOF'
# Generated by makevn. Remove with `makevn uninstall`.
include .makevn/makevn.mk
EOF
}

makevn_write_bootstrap_makefile() {
  local repo_root="$1"
  makevn_bootstrap_makefile_content > "${repo_root}/Makefile"
}

makevn_is_managed_bootstrap_makefile() {
  local repo_root="$1"
  local makefile_path="${repo_root}/Makefile"
  [[ -f "${makefile_path}" ]] || return 1
  cmp -s <(makevn_bootstrap_makefile_content) "${makefile_path}"
}

makevn_run_command_configured() {
  local repo_root="$1"
  local maven_base_path="$2"

  makevn_load_config "${repo_root}"
  if [[ -z "${MAKEVN_RUN_CMD:-}" ]]; then
    makevn_die "No run command configured. Set MAKEVN_RUN_CMD in .makevn/config first."
  fi

  makevn_run_in_context "${repo_root}" code "${maven_base_path}" bash -lc "${MAKEVN_RUN_CMD}"
}
