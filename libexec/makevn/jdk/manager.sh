#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
JDK_VERSION="${2:-}"
JDK_HOME_ARG="${3:-}"
CONFIG_FILE="${CONFIG_FILE:-makevn.config}"

extract_tool_versions_jdk_major() {
  local tool_versions_file="$1"
  local configured_jdk
  local major

  [[ -f "${tool_versions_file}" ]] || return 1
  configured_jdk="$(awk '$1 == "ivm-java" { print $2; exit }' "${tool_versions_file}")"
  [[ -n "${configured_jdk}" ]] || return 1
  major="$(printf '%s\n' "${configured_jdk}" | sed -E 's/.*-([0-9]+)(\..*)?$/\1/')"
  [[ "${major}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${major}"
}

candidate_bases=(
  "$HOME/.sdkman/candidates/java"
  "$HOME/.asdf/installs/java"
  "$HOME/.jenv/versions"
  "/Library/Java/JavaVirtualMachines"
  "$HOME/Library/Java/JavaVirtualMachines"
  "/usr/lib/jvm"
  "/mnt/c/Program Files/Java"
  "/mnt/c/Program Files/Eclipse Adoptium"
  "/mnt/c/Program Files/Microsoft"
  "/mnt/c/Program Files/Amazon Corretto"
  "/mnt/c/Program Files/Azul"
  "/c/Program Files/Java"
  "/c/Program Files/Eclipse Adoptium"
  "/c/Program Files/Microsoft"
  "/c/Program Files/Amazon Corretto"
  "/c/Program Files/Azul"
)

normalize_home() {
  local home="$1"
  if [[ -d "${home}/Contents/Home" ]]; then
    home="${home}/Contents/Home"
  fi
  printf '%s\n' "${home}"
}

java_cmd_for_home() {
  local home
  home="$(normalize_home "$1")"
  if [[ -x "${home}/bin/java" ]]; then
    printf '%s\n' "${home}/bin/java"
  elif [[ -x "${home}/bin/java.exe" ]]; then
    printf '%s\n' "${home}/bin/java.exe"
  fi
}

has_java() {
  [[ -n "$(java_cmd_for_home "$1")" ]]
}

java_version_line() {
  local cmd
  cmd="$(java_cmd_for_home "$1")"
  "${cmd}" -version 2>&1 | head -1
}

matches_version() {
  local home="$1"
  local version_line
  version_line="$(java_version_line "${home}")"
  [[ "${version_line}" =~ \"${JDK_VERSION}(\.|\+|-|\"|[[:space:]]) ]]
}

add_home_to_list() {
  local home
  local label="$2"
  home="$(normalize_home "$1")"
  if ! has_java "${home}"; then
    return 0
  fi
  if grep -Fxq "${home}" "${SEEN_FILE}"; then
    return 0
  fi
  printf '%s\n' "${home}" >> "${SEEN_FILE}"
  printf '  %-14s %s\n    %s\n' "${label}" "${home}" "$(java_version_line "${home}")"
}

list_from_java_home() {
  local output
  if [[ ! -x /usr/libexec/java_home ]]; then
    return 0
  fi
  output="$(/usr/libexec/java_home -V 2>&1 || true)"
  printf '%s\n' "${output}" | sed -n 's#.* \(/.*\.jdk/Contents/Home\).*#\1#p' | while IFS= read -r home; do
    add_home_to_list "${home}" "java_home"
  done
}

list_from_brew() {
  local formulas
  if ! command -v brew >/dev/null 2>&1; then
    return 0
  fi
  formulas="$(brew list --formula 2>/dev/null | grep -E '^(openjdk|temurin|zulu|liberica)(@[0-9]+)?$' || true)"
  printf '%s\n' "${formulas}" | while IFS= read -r formula; do
    [[ -n "${formula}" ]] || continue
    local prefix
    prefix="$(brew --prefix "${formula}" 2>/dev/null || true)"
    add_home_to_list "${prefix}/libexec/openjdk.jdk/Contents/Home" "brew:${formula}"
  done
}

list_from_common_dirs() {
  local base
  local candidate
  for base in "${candidate_bases[@]}"; do
    [[ -d "${base}" ]] || continue
    for candidate in "${base}"/* "${base}"/*/Contents/Home; do
      [[ -e "${candidate}" ]] || continue
      add_home_to_list "${candidate}" "$(basename "${base}")"
    done
  done
}

list_jdks() {
  SEEN_FILE="$(mktemp)"
  export SEEN_FILE
  trap 'rm -f "${SEEN_FILE}"' EXIT
  echo "Detected local JDKs:"
  if [[ -n "${JAVA_HOME:-}" ]]; then
    add_home_to_list "${JAVA_HOME}" "JAVA_HOME"
  fi
  list_from_java_home
  list_from_brew
  list_from_common_dirs
  if [[ ! -s "${SEEN_FILE}" ]]; then
    echo "  No JDKs detected. You can still use: makevn jdk list after installing one."
  fi
}

try_resolve_home() {
  local home
  home="$(normalize_home "$1")"
  if has_java "${home}" && matches_version "${home}"; then
    printf '%s\n' "${home}"
    return 0
  fi
  return 1
}

resolve_from_java_home() {
  local candidate
  if [[ ! -x /usr/libexec/java_home ]]; then
    return 1
  fi
  candidate="$(/usr/libexec/java_home -v "${JDK_VERSION}" 2>/dev/null || true)"
  [[ -n "${candidate}" ]] && try_resolve_home "${candidate}"
}

resolve_from_brew() {
  local formula
  local prefix
  if ! command -v brew >/dev/null 2>&1; then
    return 1
  fi
  for formula in "openjdk@${JDK_VERSION}" "temurin@${JDK_VERSION}" "zulu@${JDK_VERSION}" "liberica@${JDK_VERSION}" "openjdk" "temurin" "zulu" "liberica"; do
    prefix="$(brew --prefix "${formula}" 2>/dev/null || true)"
    [[ -n "${prefix}" ]] || continue
    try_resolve_home "${prefix}/libexec/openjdk.jdk/Contents/Home" && return 0
  done
  return 1
}

resolve_from_common_dirs() {
  local base
  local candidate
  for base in "${candidate_bases[@]}"; do
    [[ -d "${base}" ]] || continue
    for candidate in "${base}"/* "${base}"/*/Contents/Home; do
      [[ -e "${candidate}" ]] || continue
      try_resolve_home "${candidate}" && return 0
    done
  done
  return 1
}

resolve_jdk_home() {
  local home
  if [[ -n "${JDK_HOME_ARG}" ]]; then
    home="$(normalize_home "${JDK_HOME_ARG}")"
    has_java "${home}" && printf '%s\n' "${home}" && return 0
    return 1
  fi
  if [[ "${JDK_VERSION}" == /* ]]; then
    home="$(normalize_home "${JDK_VERSION}")"
    has_java "${home}" && printf '%s\n' "${home}" && return 0
    return 1
  fi
  if [[ -n "${JAVA_HOME:-}" ]]; then
    try_resolve_home "${JAVA_HOME}" && return 0
  fi
  resolve_from_java_home && return 0
  resolve_from_brew && return 0
  resolve_from_common_dirs && return 0
  return 1
}

resolve_tool_versions_home() {
  local tool_versions_file="$1"
  local resolved_major
  local previous_jdk_version="${JDK_VERSION}"
  local previous_jdk_home_arg="${JDK_HOME_ARG}"
  local resolved_home=""

  if ! resolved_major="$(extract_tool_versions_jdk_major "${tool_versions_file}")"; then
    return 1
  fi
  JDK_VERSION="${resolved_major}"
  JDK_HOME_ARG=""
  if ! resolved_home="$(resolve_jdk_home)"; then
    JDK_VERSION="${previous_jdk_version}"
    JDK_HOME_ARG="${previous_jdk_home_arg}"
    return 1
  fi
  JDK_VERSION="${previous_jdk_version}"
  JDK_HOME_ARG="${previous_jdk_home_arg}"
  printf '%s\n' "${resolved_home}"
}

resolve_version_home() {
  [[ -n "${JDK_VERSION}" ]] || return 1
  resolve_jdk_home
}

show_contexts() {
  local code_tool_versions="$1"
  local karate_tool_versions="$2"
  local code_home=""
  local karate_home=""
  echo "Global JAVA_HOME override: ${JAVA_HOME:-not set}"
  echo ""
  if [[ -n "${JAVA_HOME:-}" ]]; then
    echo "Effective code JDK: ${JAVA_HOME}"
    java_version_line "${JAVA_HOME}" || true
    echo ""
    echo "Effective karate JDK: ${JAVA_HOME}"
    java_version_line "${JAVA_HOME}" || true
    return 0
  fi
  if code_home="$(resolve_tool_versions_home "${code_tool_versions}")"; then
    echo "Effective code JDK: ${code_home}"
    java_version_line "${code_home}"
  else
    echo "Effective code JDK: unresolved (${code_tool_versions})"
  fi
  echo ""
  if karate_home="$(resolve_tool_versions_home "${karate_tool_versions}")"; then
    echo "Effective karate JDK: ${karate_home}"
    java_version_line "${karate_home}"
  else
    echo "Effective karate JDK: unresolved (${karate_tool_versions})"
  fi
}

case "${ACTION}" in
  current-contexts)
    show_contexts "${JDK_VERSION}" "${JDK_HOME_ARG}"
    ;;
  list)
    list_jdks
    ;;
  resolve-tool-versions)
    resolve_tool_versions_home "${JDK_VERSION}"
    ;;
  resolve-version)
    resolve_version_home
    ;;
  *)
    echo "Usage: $0 current-contexts|list|resolve-tool-versions|resolve-version [arg1] [arg2]"
    exit 1
    ;;
esac
