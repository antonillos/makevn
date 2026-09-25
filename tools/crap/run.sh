#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT_DIR}/target/crap"
BASELINE="${ROOT_DIR}/tools/crap/baseline.json"
BASE_BASELINE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-baseline) BASE_BASELINE="$2"; shift 2 ;;
    *) printf 'Error: unsupported CRAP option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

mkdir -p "${OUT_DIR}"
"${ROOT_DIR}/tools/crap/rust-crap.sh"
"${ROOT_DIR}/tools/crap/shell-crap.sh"
args=(--rust "${OUT_DIR}/rust-report.json" --shell "${OUT_DIR}/shell-report.json" --baseline "${BASELINE}" --output-dir "${OUT_DIR}" --threshold 8)
[[ -z "${BASE_BASELINE}" ]] || args+=(--base-baseline "${BASE_BASELINE}")
python3 "${ROOT_DIR}/tools/crap/report.py" "${args[@]}"
