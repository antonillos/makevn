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
BUILD_SCRIPT="${SCRIPT_DIR}/build-rust-dispatcher.sh"
FRONTEND_MODE="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rust)
      FRONTEND_MODE="rust"
      shift
      ;;
    --shell)
      FRONTEND_MODE="shell"
      shift
      ;;
    --help|-h)
      printf 'Usage: ./install.sh [--rust|--shell]\n'
      exit 0
      ;;
    *)
      printf 'Error: unknown install option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "${BIN_DIR}" "${LIBEXEC_DIR}" "${SHARE_DIR}" "${SKILL_DIR}"

if [[ "${FRONTEND_MODE}" == "rust" && ! -x "${RUST_BIN}" ]]; then
  printf 'Error: Rust dispatcher not built at %s\n' "${RUST_BIN}" >&2
  printf 'Build it first with %s\n' "${BUILD_SCRIPT}" >&2
  exit 1
fi

if [[ "${FRONTEND_MODE}" != "shell" && -x "${RUST_BIN}" ]]; then
  cp "${RUST_BIN}" "${BIN_DIR}/makevn"
  installed_frontend="rust"
else
  cp "${SCRIPT_DIR}/bin/makevn" "${BIN_DIR}/makevn"
  installed_frontend="shell"
fi

cp "${SCRIPT_DIR}/libexec/makevn/cli.sh" "${LIBEXEC_DIR}/cli.sh"
cp "${SCRIPT_DIR}/libexec/makevn/backend.sh" "${LIBEXEC_DIR}/backend.sh"
cp "${SCRIPT_DIR}/libexec/makevn/common.sh" "${LIBEXEC_DIR}/common.sh"
rm -rf "${LIBEXEC_DIR}/commands" "${LIBEXEC_DIR}/common"
rm -rf "${LIBEXEC_DIR}/compat" "${LIBEXEC_DIR}/coverage" "${LIBEXEC_DIR}/docker" "${LIBEXEC_DIR}/jdk"
cp -R "${SCRIPT_DIR}/libexec/makevn/commands" "${LIBEXEC_DIR}/commands"
cp -R "${SCRIPT_DIR}/libexec/makevn/common" "${LIBEXEC_DIR}/common"
cp -R "${SCRIPT_DIR}/libexec/makevn/coverage" "${LIBEXEC_DIR}/coverage"
cp -R "${SCRIPT_DIR}/libexec/makevn/docker" "${LIBEXEC_DIR}/docker"
cp -R "${SCRIPT_DIR}/libexec/makevn/jdk" "${LIBEXEC_DIR}/jdk"
cp -R "${SCRIPT_DIR}/libexec/makevn/compat" "${LIBEXEC_DIR}/compat"
cp -R "${SCRIPT_DIR}/share/makevn/." "${SHARE_DIR}/"
cp -R "${SCRIPT_DIR}/skills/makevn/." "${SKILL_DIR}/"

chmod +x "${BIN_DIR}/makevn" "${LIBEXEC_DIR}/cli.sh" "${LIBEXEC_DIR}/backend.sh" "${LIBEXEC_DIR}/common.sh"
find "${LIBEXEC_DIR}/commands" "${LIBEXEC_DIR}/coverage" "${LIBEXEC_DIR}/docker" "${LIBEXEC_DIR}/jdk" "${LIBEXEC_DIR}/compat" -type f -name '*.sh' -exec chmod +x {} +

printf 'Installed makevn to %s\n' "${PREFIX}"
if [[ "${installed_frontend}" == "rust" ]]; then
  printf 'Installed Rust dispatcher from %s\n' "${RUST_BIN}"
elif [[ "${FRONTEND_MODE}" == "shell" ]]; then
  printf 'Installed the current shell entrypoint by request.\n'
else
  printf 'Rust dispatcher not built; installed the current shell entrypoint fallback.\n'
  printf 'Build it first with %s if you want the Rust frontend.\n' "${BUILD_SCRIPT}"
fi
printf 'Add %s to PATH if needed.\n' "${BIN_DIR}"
