#!/usr/bin/env bash

makevn_scoped_coverage_state() {
  printf '%s/focused-coverage\n' "$(makevn_state_dir "$1")"
}

makevn_scoped_coverage_prepare() {
  python3 "${MAKEVN_LIBEXEC_DIR}/common/scoped_coverage.py" prepare "$1" "$(makevn_scoped_coverage_state "$1")" "${MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH}" "${MAKEVN_VERIFY_CHANGES_MODULE_SELECTION}" "${MAKEVN_VERIFY_CHANGES_SRC_FILES}" "${MAKEVN_VERIFY_CHANGES_PARENT_SPEC}"
}

makevn_scoped_coverage_finish() {
  python3 "${MAKEVN_LIBEXEC_DIR}/common/scoped_coverage.py" finish "$1" "$(makevn_scoped_coverage_state "$1")"
}

makevn_scoped_coverage_report() {
  local repo_root="$1" base="$2" maven java_home output_file result rc=0
  maven="$(makevn_maven_executable "${repo_root}" "${base}")" || return $?
  java_home="$(makevn_effective_java_home "${repo_root}" code "${base}")" || return $?
  [[ -n "${java_home}" && -x "${java_home}/bin/java" ]] || { printf "Error: configured code JDK is required for focused coverage; run makevn doctor.\n" >&2; return 1; }
  output_file="$(mktemp)"
  if python3 "${MAKEVN_LIBEXEC_DIR}/common/scoped_coverage.py" report "${repo_root}" "$(makevn_scoped_coverage_state "${repo_root}")" "${maven}" "${java_home}/bin/java" "${3:-}" > "${output_file}"; then
    result="$(tail -n 1 "${output_file}")"
    printf '%s\n' "${result}"
  else
    cat "${output_file}" >&2
    rc=1
  fi
  rm -f "${output_file}"
  return "${rc}"
}
