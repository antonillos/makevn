#!/usr/bin/env bash
set -euo pipefail

source_repo="${1:-${MAKEVN_REAL_DEMO_SOURCE:-}}"
target_repo="${2:-/tmp/makevn-real-demo}"

if [[ -z "${source_repo}" ]]; then
  printf '%s\n' "usage: setup-real-repo.sh <source-repo> [target-repo]" >&2
  exit 64
fi

rm -rf "${target_repo}"
git clone --quiet "${source_repo}" "${target_repo}"

printf '%s\n' "${target_repo}"
