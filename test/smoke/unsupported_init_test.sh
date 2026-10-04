#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKEND="${ROOT_DIR}/libexec/makevn/backend.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
printf '[package]\nname = "rust-only"\nversion = "0.1.0"\n' >"${TMP}/Cargo.toml"
for state in fresh initialized stale; do
  if [[ "${state}" == initialized ]]; then
    printf '<project/>\n' >"${TMP}/pom.xml"
    bash "${BACKEND}" init --repo "${TMP}" >/dev/null
    rm "${TMP}/pom.xml"
  elif [[ "${state}" == stale ]]; then
    sed 's/^makevn_version=.*/makevn_version=old/' "${TMP}/.makevn/manifest" >"${TMP}/manifest"
    mv "${TMP}/manifest" "${TMP}/.makevn/manifest"
  fi
  for flags in '' '--force' '--dry-run' '--force --dry-run'; do
    before="$(find "${TMP}/.makevn" -type f -exec shasum {} \; 2>/dev/null || true)"
    if output="$(bash "${BACKEND}" init --repo "${TMP}" ${flags} 2>&1)"; then
      echo 'init unexpectedly accepted a non-Maven repository' >&2
      exit 1
    fi
    [[ "${output}" == *'Cannot initialize makevn: no Maven project detected.'* ]]
    [[ "${output}" != *'Initialized makevn.'* ]]
    after="$(find "${TMP}/.makevn" -type f -exec shasum {} \; 2>/dev/null || true)"
    [[ "${before}" == "${after}" ]]
    [[ "${state}" != fresh || ! -e "${TMP}/.makevn" ]]
  done
  for compact in '' --compact; do
    output="$(bash "${BACKEND}" doctor --repo "${TMP}" ${compact} --format json)"
    printf '%s' "${output}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["repository_analysis"]["repository_support_status"] == "unsupported"; s=d["suggested_next_step"]; assert s["next"] == ""; assert s["optional"] == ""'
    output="$(bash "${BACKEND}" doctor --repo "${TMP}" ${compact})"
    [[ "${output}" != *'optional: makevn init'* && "${output}" != *'next: makevn init'* ]]
  done
done
printf '<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId><artifactId>x</artifactId><version>1</version></project>\n' >"${TMP}/pom.xml"
output="$(bash "${BACKEND}" init --repo "${TMP}" --force 2>&1)"
[[ "${output}" != *'Maven commands remain unavailable.'* ]]
echo 'Unsupported init tests passed'
