#!/usr/bin/env bash
set -euo pipefail

compose_file="${1:-.}"

[[ -f "${compose_file}" ]] || exit 0

services="$(grep -E '^  [a-z_-]+:$' "${compose_file}" | sed 's/[: ]//g' | sed 's/^  //')"
result=''

for service in ${services}; do
  section="$(sed -n "/^  ${service}:$/,/^  [a-z_-]*:$/p" "${compose_file}" | sed '$d')"
  if ! printf '%s' "${section}" | grep -q '^[[:space:]]*profiles:'; then
    result+="${service} "
  fi
done

printf '%s\n' "${result}"
