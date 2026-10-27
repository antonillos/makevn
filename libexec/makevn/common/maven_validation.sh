#!/usr/bin/env bash

makevn_require_unambiguous_maven_project() {
  local result="" status=0
  result="$(makevn_detect_maven_base_path_fresh "$1" 2>&1)" || status=$?
  if [[ "${status}" -gt 1 ]]; then
    makevn_die "${result}"
  fi
}

makevn_maven_diagnostic() {
  local repo_root="$1" base="$2" executable="$3" java_home="$4" cwd=""
  [[ -f "${base}/pom.xml" ]] || { printf '%s\n' 'not detected'; return 0; }
  cwd="$(makevn_command_working_directory "${repo_root}" "${base}" "${executable}")"
  python3 "${MAKEVN_LIBEXEC_DIR}/common/maven_inspection.py" describe "${executable}" "${base}" "${cwd}" "${java_home}" || true
}

makevn_check_maven_command() {
  local base="$1" cwd="$2" java_home="$3" executable=""
  shift 3
  if [[ "${1:-}" == env ]]; then
    shift
    while [[ "${1:-}" == *=* ]]; do shift; done
  fi
  executable="${1:-}"
  case "${executable##*/}" in
    mvn|mvnw)
      python3 "${MAKEVN_LIBEXEC_DIR}/common/maven_inspection.py" check "${executable}" "${base}" "${cwd}" "${java_home}"
      ;;
  esac
}
