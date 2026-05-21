#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-${PREFIX}/bin}"
LIBEXEC_DIR="${LIBEXEC_DIR:-${PREFIX}/libexec/makevn}"
SHARE_DIR="${SHARE_DIR:-${PREFIX}/share/makevn}"
SKILL_DIR="${SKILL_DIR:-${SHARE_DIR}/skills/makevn}"
RUST_TARGET_DIR="${SCRIPT_DIR}/target"
RUST_BIN="${RUST_TARGET_DIR}/release/makevn"
RUST_MCP_BIN="${RUST_TARGET_DIR}/release/makevn-mcp"
VERSION_ENV="${RUST_TARGET_DIR}/makevn-version.env"
BUILD_SCRIPT="${SCRIPT_DIR}/build-rust-dispatcher.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      printf 'Error: shell frontend installation is no longer supported. Build and install the Rust frontend instead.\n' >&2
      exit 1
      ;;
    --rust)
      shift
      ;;
    --help|-h)
      printf 'Usage: ./install.sh [--rust]\n'
      exit 0
      ;;
    *)
      printf 'Error: unknown install option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "${BIN_DIR}" "${LIBEXEC_DIR}" "${SHARE_DIR}" "${SKILL_DIR}"

install_executable() {
  local source="$1"
  local destination="$2"
  local tmp_destination="${destination}.tmp.$$"

  cp "${source}" "${tmp_destination}"
  chmod +x "${tmp_destination}"
  mv -f "${tmp_destination}" "${destination}"
}

if [[ ! -x "${RUST_BIN}" || ! -x "${RUST_MCP_BIN}" ]]; then
  printf 'Error: Rust dispatcher not built at %s\n' "${RUST_BIN}" >&2
  printf 'Error: Rust MCP server not built at %s\n' "${RUST_MCP_BIN}" >&2
  printf 'Build it first with %s\n' "${BUILD_SCRIPT}" >&2
  exit 1
fi

install_executable "${RUST_BIN}" "${BIN_DIR}/makevn"
install_executable "${RUST_MCP_BIN}" "${BIN_DIR}/makevn-mcp"

cp "${SCRIPT_DIR}/libexec/makevn/cli.sh" "${LIBEXEC_DIR}/cli.sh"
cp "${SCRIPT_DIR}/libexec/makevn/backend.sh" "${LIBEXEC_DIR}/backend.sh"
cp "${SCRIPT_DIR}/libexec/makevn/common.sh" "${LIBEXEC_DIR}/common.sh"
rm -f "${LIBEXEC_DIR}/version.env"
if [[ -f "${VERSION_ENV}" ]]; then
  cp "${VERSION_ENV}" "${LIBEXEC_DIR}/version.env"
fi
rm -rf "${LIBEXEC_DIR}/commands" "${LIBEXEC_DIR}/common"
rm -rf "${LIBEXEC_DIR}/compat" "${LIBEXEC_DIR}/coverage" "${LIBEXEC_DIR}/docker" "${LIBEXEC_DIR}/jdk" "${LIBEXEC_DIR}/mcp"
cp -R "${SCRIPT_DIR}/libexec/makevn/commands" "${LIBEXEC_DIR}/commands"
cp -R "${SCRIPT_DIR}/libexec/makevn/common" "${LIBEXEC_DIR}/common"
cp -R "${SCRIPT_DIR}/libexec/makevn/coverage" "${LIBEXEC_DIR}/coverage"
cp -R "${SCRIPT_DIR}/libexec/makevn/docker" "${LIBEXEC_DIR}/docker"
cp -R "${SCRIPT_DIR}/libexec/makevn/jdk" "${LIBEXEC_DIR}/jdk"
cp -R "${SCRIPT_DIR}/libexec/makevn/compat" "${LIBEXEC_DIR}/compat"
cp -R "${SCRIPT_DIR}/share/makevn/." "${SHARE_DIR}/"
cp -R "${SCRIPT_DIR}/skills/makevn/." "${SKILL_DIR}/"

chmod +x "${LIBEXEC_DIR}/cli.sh" "${LIBEXEC_DIR}/backend.sh" "${LIBEXEC_DIR}/common.sh"
find "${LIBEXEC_DIR}/commands" "${LIBEXEC_DIR}/coverage" "${LIBEXEC_DIR}/docker" "${LIBEXEC_DIR}/jdk" "${LIBEXEC_DIR}/compat" -type f -name '*.sh' -exec chmod +x {} +

printf 'Installed makevn to %s\n' "${PREFIX}"
printf 'Installed Rust dispatcher from %s\n' "${RUST_BIN}"
printf 'Installed Rust MCP server from %s\n' "${RUST_MCP_BIN}"
printf 'Add %s to PATH if needed.\n' "${BIN_DIR}"
