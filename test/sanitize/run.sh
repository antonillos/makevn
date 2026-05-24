#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

search_literal() {
  local pattern="$1"
  local output
  output="$(grep -RIn --exclude-dir=.git --exclude-dir=.idea --exclude-dir=.vscode --exclude-dir=target --exclude-dir=node_modules --exclude='run.sh' -F -e "${pattern}" "${ROOT_DIR}" || true)"
  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}" >&2
    fail "found forbidden literal: ${pattern}"
  fi
}

search_regex() {
  local pattern="$1"
  local output
  output="$(grep -RInE --exclude-dir=.git --exclude-dir=.idea --exclude-dir=.vscode --exclude-dir=target --exclude-dir=node_modules --exclude='run.sh' -e "${pattern}" "${ROOT_DIR}" || true)"
  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}" >&2
    fail "found forbidden pattern: ${pattern}"
  fi
}

search_literal "/Us""ers/antonio"
search_literal "/Us""ers/antonillos"
search_literal "antonio.saco"
search_literal "/home/antonio"
search_literal "/home/antonillos"
search_literal "/var/folders/"

search_regex "ghp_[A-Za-z0-9_]{20,}"
search_regex "github_pat_[A-Za-z0-9_]{20,}"
search_regex "sk-[A-Za-z0-9]{20,}"
search_regex "AKIA[0-9A-Z]{16}"
search_regex "-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----"

printf 'Sanitization checks passed.\n'
