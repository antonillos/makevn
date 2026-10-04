#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKEND="${ROOT_DIR}/libexec/makevn/backend.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
printf '[package]\nname = "rust-only"\nversion = "0.1.0"\n' >"${TMP}/Cargo.toml"
for state in fresh initialized stale; do
  if [[ "${state}" == initialized ]]; then
    output="$(bash "${BACKEND}" init --repo "${TMP}" 2>&1)"
    [[ "${output}" == *'No Maven project detected. init only creates local configuration; Maven commands remain unavailable.'* ]]
    [[ -f "${TMP}/.makevn/config" ]]
  elif [[ "${state}" == stale ]]; then
    sed 's/^makevn_version=.*/makevn_version=old/' "${TMP}/.makevn/manifest" >"${TMP}/manifest"
    mv "${TMP}/manifest" "${TMP}/.makevn/manifest"
  fi
  for compact in '' --compact; do
    output="$(bash "${BACKEND}" doctor --repo "${TMP}" ${compact} --format json)"
    printf '%s' "${output}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["repository_analysis"]["repository_support_status"] == "unsupported"; s=d["suggested_next_step"]; assert s["next"] == ""; assert s["optional"] == ""'
    output="$(bash "${BACKEND}" doctor --repo "${TMP}" ${compact})"
    [[ "${output}" != *'optional: makevn init'* && "${output}" != *'next: makevn init'* ]]
  done
done
bash "${BACKEND}" init --repo "${TMP}" --force --dry-run >"${TMP}/dry-run" 2>&1
grep -Fq 'Maven commands remain unavailable.' "${TMP}/dry-run"
printf '<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId><artifactId>x</artifactId><version>1</version></project>\n' >"${TMP}/pom.xml"
output="$(bash "${BACKEND}" init --repo "${TMP}" --force 2>&1)"
[[ "${output}" != *'Maven commands remain unavailable.'* ]]
echo 'Unsupported init tests passed'
