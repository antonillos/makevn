#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_MANIFEST="${SCRIPT_DIR}/rust/dispatcher/Cargo.toml"
RUST_TARGET_DIR="${SCRIPT_DIR}/target"
RUST_BIN="${RUST_TARGET_DIR}/release/makevn"
RUST_MCP_BIN="${RUST_TARGET_DIR}/release/makevn-mcp"
VERSION_ENV="${RUST_TARGET_DIR}/makevn-version.env"

if ! command -v cargo >/dev/null 2>&1; then
  printf 'Error: cargo is required to build the Rust dispatcher.\n' >&2
  exit 1
fi

base_version="$(sed -nE 's/^version = "([^"]+)"/\1/p' "${RUST_MANIFEST}" | head -n 1)"
build_stamp="$(date +"%Y.%m.%d.%H.%M")"
build_version="${base_version} (${build_stamp})"

mkdir -p "${RUST_TARGET_DIR}"
printf 'MAKEVN_VERSION=%q\n' "${build_version}" > "${VERSION_ENV}"

MAKEVN_BUILD_VERSION="${build_version}" CARGO_TARGET_DIR="${RUST_TARGET_DIR}" cargo build --quiet --release --manifest-path "${RUST_MANIFEST}"

printf 'Built Rust dispatcher at %s\n' "${RUST_BIN}"
printf 'Built Rust MCP server at %s\n' "${RUST_MCP_BIN}"
printf 'Version: %s\n' "${build_version}"
