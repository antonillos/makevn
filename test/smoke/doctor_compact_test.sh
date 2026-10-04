#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${ROOT_DIR}/bin/makevn"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
printf '<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId><artifactId>x</artifactId><version>1</version></project>\n' >"${TMP}/pom.xml"
output="$("${CLI}" --repo "${TMP}" doctor --compact)"
[[ "${output}" == *'next: makevn init'* && "${output}" != *'Resolved code JAVA_HOME'* ]]
[[ ! -e "${TMP}/.makevn" ]]
"${CLI}" --repo "${TMP}" init >/dev/null
output="$("${CLI}" --repo "${TMP}" doctor --compact)"
[[ "${output}" == *'status: initialized'* && "${output}" != *'next: makevn init'* && "${output}" != *'Suggested next step'* && "${output}" != *$'\e'* ]]
cp "${TMP}/.makevn/profile.env" "${TMP}/profile.before"
"${CLI}" --repo "${TMP}" doctor --compact >/dev/null
cmp "${TMP}/profile.before" "${TMP}/.makevn/profile.env"
sed 's/^makevn_version=.*/makevn_version=old/' "${TMP}/.makevn/manifest" >"${TMP}/manifest"
mv "${TMP}/manifest" "${TMP}/.makevn/manifest"
output="$("${CLI}" --repo "${TMP}" doctor --compact)"
[[ "${output}" == *'status: stale'* && "${output}" == *'next: makevn init --force'* ]]
# Retired commands cannot modify stale initialization or repository targets.
printf 'custom:\n\t@echo untouched\n' > "${TMP}/Makefile"
cp "${TMP}/Makefile" "${TMP}/Makefile.before"
for stored_version in old ''; do
  sed '/^makevn_version=/d' "${TMP}/.makevn/manifest" > "${TMP}/manifest"
  printf 'makevn_version=%s\n' "${stored_version}" >> "${TMP}/manifest"
  mv "${TMP}/manifest" "${TMP}/.makevn/manifest"
  for action in install uninstall; do
    if "${CLI}" --repo "${TMP}" make "${action}" >/dev/null 2>&1; then exit 1; fi
    [[ "$(sed -n 's/^makevn_version=//p' "${TMP}/.makevn/manifest")" == "${stored_version}" ]]
    output="$("${CLI}" --repo "${TMP}" doctor --compact)"
    [[ "${output}" == *'status: stale'* && "${output}" == *'next: makevn init --force'* ]]
    cmp "${TMP}/profile.before" "${TMP}/.makevn/profile.env"
    cmp "${TMP}/Makefile.before" "${TMP}/Makefile"
  done
done
cp "${TMP}/Makefile" "${TMP}/Makefile.after"
"${CLI}" --repo "${TMP}" init --force >/dev/null
cmp "${TMP}/Makefile.after" "${TMP}/Makefile"
output="$("${CLI}" --repo "${TMP}" doctor --compact)"
[[ "${output}" == *'status: initialized'* && "${output}" != *'next: makevn init'* ]]
for file in config profile.env state.json; do
  cp "${TMP}/.makevn/${file}" "${TMP}/saved"
  rm "${TMP}/.makevn/${file}"
  output="$("${CLI}" --repo "${TMP}" doctor --compact)"
  [[ "${output}" == *'status: incomplete'* && "${output}" == *'next: makevn init --force'* ]]
  mv "${TMP}/saved" "${TMP}/.makevn/${file}"
done
old_build="0.1.13 (2026.10.03.10.30)"
new_build="0.1.13 (2026.10.03.11.30)"
MAKEVN_VERSION="${old_build}" "${CLI}" --repo "${TMP}" init --force >/dev/null
MAKEVN_VERSION="${old_build}" "${CLI}" --repo "${TMP}" doctor --compact >/dev/null
output="$(MAKEVN_VERSION="${new_build}" "${CLI}" --repo "${TMP}" doctor --compact)"
[[ "${output}" == *"${old_build} -> ${new_build}"* && "${output}" == *'next: makevn init --force'* ]]
[[ "$(cat "${TMP}/.makevn/doctor-version")" == "${new_build}" ]]
# Analysis with the new build must not hide an older initialization build.
output="$(MAKEVN_VERSION="${new_build}" bash "${ROOT_DIR}/libexec/makevn/backend.sh" doctor --repo "${TMP}" --compact --format json)"
printf '%s' "${output}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["doctor_build"]["status"] == "current"; assert d["suggested_next_step"]["next"] == "makevn init --force"'
MAKEVN_VERSION="${new_build}" "${CLI}" --repo "${TMP}" init --force >/dev/null
output="$(MAKEVN_VERSION="${new_build}" "${CLI}" --repo "${TMP}" doctor --compact)"
[[ "${output}" == *'status: initialized'* && "${output}" != *'next: makevn init'* && "${output}" != *'Suggested next step'* && "${output}" != *$'\e'* ]]
printf 'Doctor compact tests passed\n'
