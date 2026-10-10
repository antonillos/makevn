#!/usr/bin/env bash

makevn_detect_karate_profiles() {
  local repo_root="$1" key value
  MAKEVN_DETECTED_KARATE_APP_PROFILES=""
  MAKEVN_DETECTED_KARATE_APP_PROFILES_STATUS="missing"
  MAKEVN_DETECTED_KARATE_APP_PROFILES_SOURCE=""
  MAKEVN_DETECTED_KARATE_APP_PROFILES_CANDIDATES=""
  command -v python3 >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r key value; do
    case "${key}" in
      profiles) MAKEVN_DETECTED_KARATE_APP_PROFILES="${value}" ;;
      status) MAKEVN_DETECTED_KARATE_APP_PROFILES_STATUS="${value}" ;;
      source) MAKEVN_DETECTED_KARATE_APP_PROFILES_SOURCE="${value}" ;;
      candidates) MAKEVN_DETECTED_KARATE_APP_PROFILES_CANDIDATES="${value}" ;;
    esac
  done < <(python3 "${MAKEVN_LIBEXEC_DIR}/common/karate_profiles.py" "${repo_root}")
}

makevn_resolve_karate_profiles() {
  local repo_root="$1"
  makevn_load_config "${repo_root}"
  makevn_detect_karate_profiles "${repo_root}"
  MAKEVN_EFFECTIVE_KARATE_APP_PROFILES="${MAKEVN_DETECTED_KARATE_APP_PROFILES}"
  MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE="CI: ${MAKEVN_DETECTED_KARATE_APP_PROFILES_SOURCE:-not detected; application defaults}"
  if [[ -n "${SPRING_PROFILES_ACTIVE+x}" ]]; then
    MAKEVN_EFFECTIVE_KARATE_APP_PROFILES="${SPRING_PROFILES_ACTIVE}"
    MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE="environment (SPRING_PROFILES_ACTIVE)"
  elif [[ -n "${MAKEVN_KARATE_APP_PROFILES:-}" ]]; then
    MAKEVN_EFFECTIVE_KARATE_APP_PROFILES="${MAKEVN_KARATE_APP_PROFILES}"
    MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE="config (MAKEVN_KARATE_APP_PROFILES)"
  fi
}

makevn_doctor_karate_profiles() {
  local repo_root="$1" app_runnable="$2" input default_value eligible="no"
  makevn_resolve_karate_profiles "${repo_root}"
  if [[ -n "$(makevn_detect_karate_base_path "${repo_root}" || true)" || "${MAKEVN_DETECTED_KARATE_APP_PROFILES_STATUS}" != missing ]]; then
    eligible="yes"
  fi
  if [[ "${eligible}" == yes && "${app_runnable}" == yes && -z "${SPRING_PROFILES_ACTIVE+x}" && -z "${MAKEVN_KARATE_APP_PROFILES:-}" && -f "$(makevn_config_path "${repo_root}")" && -t 0 && -t 2 && "${MAKEVN_COMPACT_OUTPUT:-}" != "1" ]]; then
    makevn_pause_frontend_for_prompt
    default_value="${MAKEVN_DETECTED_KARATE_APP_PROFILES:-skip}"
    makevn_print_question "Karate Spring profiles: ${MAKEVN_DETECTED_KARATE_APP_PROFILES_CANDIDATES:-not detected}"
    printf '%s\n' "$(makevn_dim "Source: ${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE}")" >&2
    input="$(makevn_read_editable_default "Karate profiles [${default_value}] (skip to leave unchanged): " "${default_value}")" || { makevn_resume_frontend_after_prompt; return 0; }
    if [[ "${input}" != skip ]]; then
      if [[ "${input}" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]]; then
        makevn_update_config_karate_profiles "${repo_root}" "${input}"
        MAKEVN_EFFECTIVE_KARATE_APP_PROFILES="${input}"
        MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE="config (MAKEVN_KARATE_APP_PROFILES)"
      else
        printf 'Invalid profiles: use a comma-separated list of literal profile names. Configuration unchanged.\n' >&2
      fi
    fi
    makevn_resume_frontend_after_prompt
  fi
  MAKEVN_DOCTOR_KARATE_APP_PROFILES="${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES:-application defaults}"
  if [[ "${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE}" == CI:* && "${MAKEVN_DETECTED_KARATE_APP_PROFILES_STATUS}" == ambiguous ]]; then
    MAKEVN_DOCTOR_KARATE_APP_PROFILES="unresolved (explicit selection required)"
  fi
  MAKEVN_DOCTOR_KARATE_APP_PROFILES_SOURCE="${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE}"
  MAKEVN_DOCTOR_KARATE_APP_PROFILES_CANDIDATES="${MAKEVN_DETECTED_KARATE_APP_PROFILES_CANDIDATES:-none}"
}

makevn_update_config_karate_profiles() {
  local config_path line tmp_file
  config_path="$(makevn_config_path "$1")"
  printf -v line 'MAKEVN_KARATE_APP_PROFILES=%q' "$2"
  tmp_file="$(mktemp)"
  MAKEVN_CONFIG_PROFILES_LINE="${line}" awk '/^MAKEVN_KARATE_APP_PROFILES=/ {next} {print} END {print ENVIRON["MAKEVN_CONFIG_PROFILES_LINE"]}' "${config_path}" > "${tmp_file}"
  mv "${tmp_file}" "${config_path}"
}
