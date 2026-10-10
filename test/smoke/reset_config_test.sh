#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
cli="${ROOT}/bin/makevn"
printf '<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId><artifactId>x</artifactId><version>1</version></project>\n' > "${tmp}/pom.xml"
"${cli}" --repo "${tmp}" doctor --compact >/dev/null
"${cli}" --repo "${tmp}" init >/dev/null
printf '\nMAKEVN_RUN_CMD="custom"\nMAKEVN_APP_HEALTH_URL="http://localhost:9999/health"\n' >> "${tmp}/.makevn/config"
cp "${tmp}/.makevn/config" "${tmp}/before"
printf 'keep logs' > "${tmp}/.makevn/logs/sentinel"
printf 'untouched' > "${tmp}/Makefile"
"${cli}" --repo "${tmp}" init --reset-config --dry-run >/dev/null
cmp "${tmp}/before" "${tmp}/.makevn/config"
[[ -z "$(find "${tmp}/.makevn" -name 'config-backup.*')" ]]
"${cli}" --repo "${tmp}" init --force >/dev/null
cmp "${tmp}/before" "${tmp}/.makevn/config"
"${cli}" --repo "${tmp}" init --reset-config >/dev/null
cmp "${tmp}/before" "${tmp}"/.makevn/config-backup.*/config
grep -q '^MAKEVN_RUN_CMD=""' "${tmp}/.makevn/config"
! grep -q MAKEVN_APP_HEALTH_URL "${tmp}/.makevn/config"
[[ -f "${tmp}/.makevn/profile.env" && -f "${tmp}/.makevn/manifest" ]]
[[ "$(cat "${tmp}/.makevn/logs/sentinel")" == 'keep logs' ]]
[[ "$(cat "${tmp}/Makefile")" == untouched ]]
rm "${tmp}/pom.xml"
cp "${tmp}/.makevn/config" "${tmp}/defaults"
if "${cli}" --repo "${tmp}" init --reset-config >/dev/null 2>&1; then exit 1; fi
cmp "${tmp}/defaults" "${tmp}/.makevn/config"
printf 'Reset configuration tests passed\n'
