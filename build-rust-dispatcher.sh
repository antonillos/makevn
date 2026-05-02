#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_MANIFEST="${SCRIPT_DIR}/rust/dispatcher/Cargo.toml"
RUST_TARGET_DIR="${SCRIPT_DIR}/target"
RUST_BIN="${RUST_TARGET_DIR}/release/makevn"

if ! command -v cargo >/dev/null 2>&1; then
  printf 'Error: cargo is required to build the Rust dispatcher.\n' >&2
  exit 1
fi

CARGO_TARGET_DIR="${RUST_TARGET_DIR}" cargo build --quiet --release --manifest-path "${RUST_MANIFEST}"

printf 'Built Rust dispatcher at %s\n' "${RUST_BIN}"
