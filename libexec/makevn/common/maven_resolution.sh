#!/usr/bin/env bash

# Resolve the declared installation directly: shims run from the repository
# root cannot see code/ or Karate pins. A missing pin must never fall back.
makevn_pinned_maven_executable() {
  local declaration file tool version
  declaration="$(makevn_maven_declaration "$@")"
  [[ -n "${declaration}" ]] || return 0
  IFS=$'\t' read -r file tool version <<< "${declaration}"
  makevn_declared_maven_executable "${file}" "${tool}" "${version}"
}

makevn_maven_declaration() {
  local repo_root="$1" context="$2" base_path="$3"
  local configured_file="" file="" declaration=""
  makevn_load_config "${repo_root}"
  if [[ "${context}" == karate ]]; then
    configured_file="${MAKEVN_KARATE_TOOL_VERSIONS:-}"
  else
    configured_file="${MAKEVN_CODE_TOOL_VERSIONS:-}"
  fi
  for file in "${configured_file}" "${base_path}/.tool-versions" "${repo_root}/.tool-versions"; do
    [[ -n "${file}" && -f "${file}" ]] || continue
    declaration="$(awk '($1 == "maven" || $1 == "ivm-maven") { printf "%s\t%s", $1, $2; exit }' "${file}")"
    [[ -n "${declaration}" ]] || continue
    printf '%s\t%s\n' "${file}" "${declaration}"
    return 0
  done
}

makevn_mvnd_status() {
  local repo_root="$1" base_path="$2" declaration
  makevn_load_config "${repo_root}"
  MAKEVN_MVND_PREFERENCE="${MAKEVN_USE_MVND:-automatic}"
  MAKEVN_MVND_STATUS=missing
  MAKEVN_MVND_PIN=""
  type -P mvnd >/dev/null 2>&1 || return 0
  MAKEVN_MVND_STATUS=maven
  case "${MAKEVN_MVND_PREFERENCE}" in
    TRUE) MAKEVN_MVND_STATUS=mvnd; return 0 ;;
    FALSE) return 0 ;;
  esac
  declaration="$(makevn_maven_declaration "${repo_root}" code "${base_path}")"
  if [[ -n "${declaration}" ]]; then
    MAKEVN_MVND_PIN="${declaration//$'\t'/ }"
  elif [[ -x "${repo_root}/mvnw" || ( -n "${base_path}" && -x "${base_path}/mvnw" ) ]]; then
    MAKEVN_MVND_PIN="Maven Wrapper (mvnw)"
  fi
  MAKEVN_MVND_STATUS=mvnd
  [[ -z "${MAKEVN_MVND_PIN}" ]] || MAKEVN_MVND_STATUS=confirmation
}

MAKEVN_MVND_INSTALL_HINT="Install with sdk install mvnd or see https://github.com/apache/maven-mvnd#how-to-install-mvnd. Run mvnd --version and ensure mvnd is on the MakeVN process PATH."

makevn_declared_maven_executable() {
  local file="$1" tool="$2" version="$3" executable=""
  if [[ "${version}" == system ]]; then
    makevn_system_maven_executable "${file}"
    return $?
  fi
  if ! makevn_maven_pin_is_valid "${version}"; then
    makevn_die "Invalid Maven pin in ${file}: ${tool} ${version}"
    return 1
  fi
  executable="${ASDF_DATA_DIR:-$HOME/.asdf}/installs/${tool}/${version}/bin/mvn"
  if [[ ! -x "${executable}" ]]; then
    makevn_die "Maven ${tool} ${version} declared in ${file} is not installed at ${executable}. Install the declared version before continuing."
    return 1
  fi
  printf '%s\n' "${executable}"
}

makevn_maven_pin_is_valid() {
  [[ -n "$1" && "$1" != */* && "$1" != . && "$1" != .. ]]
}

# Resolve physical directories so an alias of the shim directory is excluded too.
makevn_system_maven_candidate() {
  local directory="$1" shim_directory="$2"
  directory="$(CDPATH= cd -P -- "${directory:-.}" 2>/dev/null && pwd -P)" || return 1
  [[ "${directory}" != "${shim_directory}" ]] || return 1
  [[ -x "${directory}/mvn" && ! -d "${directory}/mvn" ]] || return 1
  printf '%s/mvn\n' "${directory}"
}

makevn_system_maven_executable() {
  local file="$1" directory="" executable=""
  local shim_directory="${ASDF_DATA_DIR:-$HOME/.asdf}/shims"
  local -a directories=()
  shim_directory="$(CDPATH= cd -P -- "${shim_directory}" 2>/dev/null && pwd -P)" || shim_directory="${ASDF_DATA_DIR:-$HOME/.asdf}/shims"
  IFS=: read -r -a directories <<< "${PATH}"
  for directory in "${directories[@]}"; do
    executable="$(makevn_system_maven_candidate "${directory}" "${shim_directory}")" || continue
    printf '%s\n' "${executable}"
    return 0
  done
  makevn_die "Maven system declared in ${file}, but no non-asdf system mvn executable was found in PATH. Install system Maven or update the declaration."
}
