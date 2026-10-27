#!/usr/bin/env bash

makevn_automatic_java_homes() {
  local base="$1" version="$2" ranges="" homes="" java_home="${JAVA_HOME:-}"
  if [[ -z "${version}" ]]; then
    ranges="$(makevn_java_enforcer_ranges "${base}")"
    [[ -n "${ranges}" && "${ranges}" != '!'* ]] || return 0
    version=1
  fi
  homes="$(MAKEVN_JDK_MAVEN_BASE_PATH="${base}" makevn_list_compatible_java_homes "${version}")"
  if [[ -d "${java_home}/Contents/Home" ]]; then
    java_home="${java_home}/Contents/Home"
  fi
  if [[ -n "${java_home}" ]] && grep -Fxq "${java_home}" <<< "${homes}"; then
    printf '%s\n' "${java_home}"
  else
    printf '%s\n' "${homes}"
  fi
}

makevn_resolve_single_java_home() {
  local homes=""
  homes="$(makevn_automatic_java_homes "$1" "$2")"
  [[ -n "${homes}" && "${homes}" != *$'\n'* ]] || return 1
  printf '%s\n' "${homes}"
}

makevn_doctor_java_selection() {
  local repo="$1" base="$2" version="$3" pins="$4" home="" count=0
  MAKEVN_DOCTOR_JAVA_CANDIDATES=""
  MAKEVN_DOCTOR_JAVA_RECOMMENDED=""
  MAKEVN_DOCTOR_JAVA_DETAILS=""
  MAKEVN_DOCTOR_JAVA_ERROR=""
  [[ -n "${base}" ]] || return 0
  if [[ -z "${MAKEVN_CODE_JAVA_HOME:-}${MAKEVN_JAVA_HOME:-}${pins}" ]]; then
    MAKEVN_DOCTOR_JAVA_CANDIDATES="$(makevn_automatic_java_homes "${base}" "${version}")"
    while IFS= read -r home; do
      if [[ -n "${home}" ]]; then
        count=$((count + 1))
        MAKEVN_DOCTOR_JAVA_DETAILS+="${home}: $(makevn_java_version_line "${home}")"$'\n'
      fi
    done <<< "${MAKEVN_DOCTOR_JAVA_CANDIDATES}"
    if (( count > 1 )); then
      code_java_home_recommendation="Multiple compatible JDKs detected. Choose code_java_home through doctor_configure or interactive makevn doctor."
      MAKEVN_DOCTOR_JAVA_RECOMMENDED="$(MAKEVN_JDK_MAVEN_BASE_PATH="${base}" makevn_resolve_compatible_java_version_home "${version:-1}")"
      makevn_prompt_doctor_java "${repo}"
      return 0
    fi
    MAKEVN_DOCTOR_JAVA_CANDIDATES=""
  fi
  if [[ -n "${version}${java_enforcer_ranges:-}${pins}${MAKEVN_CODE_JAVA_HOME:-}${MAKEVN_JAVA_HOME:-}" ]] &&
      [[ -z "${code_java_home}" || ! -d "${code_java_home}" || ! -x "${code_java_home}/bin/java" && ! -x "${code_java_home}/bin/java.exe" ]]; then
    MAKEVN_DOCTOR_JAVA_ERROR="No usable JDK satisfies the repository Java requirement (${version:-${java_enforcer_ranges:-explicit selection}}). Install a compatible JDK and run makevn doctor again. ${code_java_home_recommendation}"
  fi
}

makevn_prompt_doctor_java() {
  local repo="$1" home="" choice="" index=0
  local homes=()
  [[ -f "$(makevn_config_path "${repo}")" && -t 0 && -t 2 && "${MAKEVN_COMPACT_OUTPUT:-}" != 1 && "${FORMAT:-}" != json ]] || return 0
  makevn_pause_frontend_for_prompt
  makevn_print_question 'Which compatible JDK should this repository use?'
  while IFS= read -r home; do
    homes+=("${home}")
    index=$((index + 1))
    printf '  [%s] %s (%s)\n' "${index}" "${home}" "$(makevn_java_version_line "${home}")" >&2
  done <<< "${MAKEVN_DOCTOR_JAVA_CANDIDATES}"
  printf 'Recommended (lowest compatible major): %s\n' "${MAKEVN_DOCTOR_JAVA_RECOMMENDED}" >&2
  while true; do
    printf 'Enter number [1-%s]: ' "${#homes[@]}" >&2
    makevn_read_choice_into choice
    if [[ "${choice}" =~ ^[1-9][0-9]*$ ]] && (( choice <= ${#homes[@]} )); then
      code_java_home="${homes[$((choice - 1))]}"
      python3 "${MAKEVN_LIBEXEC_DIR}/common/doctor_setup.py" set "$(makevn_config_path "${repo}")" MAKEVN_CODE_JAVA_HOME "${code_java_home}"
      MAKEVN_DOCTOR_JAVA_CANDIDATES=""
      code_java_home_recommendation=""
      break
    fi
  done
  makevn_resume_frontend_after_prompt
}

makevn_print_doctor_java_error() {
  if [[ -n "${MAKEVN_DOCTOR_JAVA_ERROR:-}" ]]; then
    makevn_print_item "Code JDK error" "${MAKEVN_DOCTOR_JAVA_ERROR}"
  fi
}
