#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT_DIR}/target/crap"

command -v cargo >/dev/null 2>&1 || { printf 'Error: cargo is required.\n' >&2; exit 2; }
cargo llvm-cov --version >/dev/null 2>&1 || { printf 'Error: cargo-llvm-cov is required.\n' >&2; exit 2; }
cargo crap --version >/dev/null 2>&1 || { printf 'Error: cargo-crap is required.\n' >&2; exit 2; }

mkdir -p "${OUT_DIR}"
cargo llvm-cov \
  --manifest-path "${ROOT_DIR}/rust/dispatcher/Cargo.toml" \
  --all-targets --lcov --output-path "${OUT_DIR}/rust-coverage.lcov" \
  >"${OUT_DIR}/rust-coverage.log" 2>&1 || {
    tail -n 80 "${OUT_DIR}/rust-coverage.log" >&2
    exit 2
  }

cargo crap \
  --path "${ROOT_DIR}/rust/dispatcher" \
  --lcov "${OUT_DIR}/rust-coverage.lcov" \
  --threshold 8 --format json --output "${OUT_DIR}/rust-report.json" \
  >"${OUT_DIR}/rust-crap.log" 2>&1 || {
    rc=$?
    tail -n 80 "${OUT_DIR}/rust-crap.log" >&2
    [[ ${rc} -eq 1 && -s "${OUT_DIR}/rust-report.json" ]] || exit 2
  }

python3 - "${OUT_DIR}/rust-report.json" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
if not isinstance(payload.get("entries"), list) or not payload["entries"]:
    raise SystemExit("Error: cargo-crap produced no Rust entries.")
PY
