#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT_DIR}/target/crap"
SHELLMETRICS="${SHELLMETRICS:-shellmetrics}"
BASH_BIN="${MAKEVN_CRAP_BASH:-$(command -v bash)}"
BASHCOV="${BASHCOV:-$(command -v bashcov 2>/dev/null || true)}"
if [[ -z "${BASHCOV}" ]] && command -v ruby >/dev/null 2>&1; then
  ruby_gem_bin="$(ruby -e 'print Gem.bindir' 2>/dev/null || true)"
  [[ -x "${ruby_gem_bin}/bashcov" ]] && BASHCOV="${ruby_gem_bin}/bashcov"
fi

[[ -x "${BASHCOV}" ]] || { printf 'Error: bashcov is required.\n' >&2; exit 2; }
command -v "${SHELLMETRICS}" >/dev/null 2>&1 || { printf 'Error: shellmetrics is required.\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'Error: python3 is required.\n' >&2; exit 2; }
"${BASH_BIN}" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null || {
  printf 'Error: bashcov requires Bash 4 or newer. Set MAKEVN_CRAP_BASH (for example, to Homebrew bash).\n' >&2
  exit 2
}

mkdir -p "${OUT_DIR}"
rm -rf "${OUT_DIR}/shell-coverage"
(
  cd "${ROOT_DIR}"
  BASHCOV_COMMAND_NAME=makevn-smoke "${BASHCOV}" --bash-path "${BASH_BIN}" -- test/smoke/run.sh
) >"${OUT_DIR}/shell-coverage.log" 2>&1 || {
  tail -n 80 "${OUT_DIR}/shell-coverage.log" >&2
  exit 2
}

mapfile -t sources < <(
  cd "${ROOT_DIR}"
  {
    printf '%s\n' bin/makevn
    find libexec/makevn -type f -name '*.sh' -print
    find . -maxdepth 1 -type f -name '*.sh' -print | sed 's|^./||'
  } | LC_ALL=C sort -u
)
[[ ${#sources[@]} -gt 0 ]] || { printf 'Error: no production shell sources found.\n' >&2; exit 2; }
(
  cd "${ROOT_DIR}"
  "${SHELLMETRICS}" --no-color --csv "${sources[@]}"
) >"${OUT_DIR}/shell-complexity.csv"

python3 "${ROOT_DIR}/tools/crap/shell_report.py" \
  --root "${ROOT_DIR}" \
  --complexity "${OUT_DIR}/shell-complexity.csv" \
  --coverage "${OUT_DIR}/shell-coverage/.resultset.json" \
  --bash "${BASH_BIN}" \
  --output "${OUT_DIR}/shell-report.json"
