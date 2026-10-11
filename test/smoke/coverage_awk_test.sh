#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/report"
touch "${tmp}/report/index.html"
awk '/^# Detect changed production Java files/ {exit} {print}' "${ROOT}/libexec/makevn/coverage/changes.sh" > "${tmp}/functions.sh"
git init -q "${tmp}/repo"
cd "${tmp}/repo"
printf 'one\ntwo\nthree\n' > Owner.java
git add .
git -c user.name=Test -c user.email=test@example.com commit -qm base
git branch develop
git checkout -qb feature
printf 'one\nchanged two\nthree\n' > Owner.java
git add .
git -c user.name=Test -c user.email=test@example.com commit -qm first
printf 'one\nchanged two\nchanged three\n' > Owner.java
git add .
git -c user.name=Test -c user.email=test@example.com commit -qm second
source "${tmp}/functions.sh" "${tmp}/report" develop...HEAD
output="$(first_parent_added_line_numbers Owner.java 2> "${tmp}/stderr")"
[[ "${output}" == $'2\n3' && ! -s "${tmp}/stderr" ]]
awk() { return 1; }
if first_parent_added_line_numbers Owner.java > /dev/null 2>&1; then
  printf 'Failed awk must not become successful empty coverage\n' >&2
  exit 1
fi
printf 'Multiline commit-list awk regression passed\n'
