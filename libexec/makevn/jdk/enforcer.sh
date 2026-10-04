#!/usr/bin/env bash

makevn_java_enforcer_ranges() {
  local base="$1"
  [[ -f "${base}/pom.xml" ]] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    if grep -qE 'requireJavaVersion|<parent' "${base}/pom.xml"; then
      printf '%s' '!python3 is required to inspect Maven Enforcer Java constraints'
    fi
    return 0
  fi
  python3 "$(dirname "${BASH_SOURCE[0]}")/enforcer.py" rules "${base}" || true
}

jdk_satisfies_enforcer() {
  local home="$1" version="" rule=""
  local ranges=()
  [[ -n "${enforcer_ranges:-}" ]] || return 0
  [[ "${enforcer_ranges}" != '!'* ]] || return 1
  version="$(java_version_line "${home}" | sed -nE 's/.*version "([^"]+)".*/\1/p')"
  while IFS= read -r rule; do
    ranges+=("${rule}")
  done <<< "${enforcer_ranges}"
  python3 "$(dirname "${BASH_SOURCE[0]}")/enforcer.py" match "${version}" "${ranges[@]}"
}
