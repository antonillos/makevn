#!/usr/bin/env bash

# Resolve the declared installation directly: shims run from the repository
# root cannot see code/ or Karate pins. A missing pin must never fall back.
makevn_pinned_maven_executable() {
  local repo_root="$1" context="$2" base_path="$3"
  local configured_file="" file="" declaration="" tool="" version=""
  makevn_load_config "${repo_root}"
  if [[ "${context}" == karate ]]; then
    configured_file="${MAKEVN_KARATE_TOOL_VERSIONS:-}"
  else
    configured_file="${MAKEVN_CODE_TOOL_VERSIONS:-}"
  fi
  for file in "${configured_file}" "${base_path}/.tool-versions" "${repo_root}/.tool-versions"; do
    [[ -n "${file}" && -f "${file}" ]] || continue
    declaration="$(awk '($1 == "maven" || $1 == "ivm-maven") { print $1, $2; exit }' "${file}")"
    [[ -n "${declaration}" ]] || continue
    read -r tool version <<< "${declaration}"
    makevn_declared_maven_executable "${file}" "${tool}" "${version}"
    return 0
  done
}

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
