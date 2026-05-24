#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: build-runtime-archive.sh <version> <target> [dist-dir]}"
TARGET="${2:?usage: build-runtime-archive.sh <version> <target> [dist-dir]}"
DIST_DIR="${3:-dist}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)"
if [[ "${DIST_DIR}" = /* ]]; then
  DIST_ROOT="${DIST_DIR}"
else
  DIST_ROOT="${ROOT_DIR}/${DIST_DIR}"
fi
SEMVER="${VERSION#v}"
ARCHIVE_NAME="makevn-${VERSION}-${TARGET}.tar.gz"
ARCHIVE_PATH="${DIST_ROOT}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
STAGE_DIR="${DIST_ROOT}/makevn-${SEMVER}-${TARGET}"

if [[ -n "${MAKEVN_BIN_DIR:-}" ]]; then
  BIN_SOURCE_DIR="${MAKEVN_BIN_DIR}"
elif [[ -x "${ROOT_DIR}/target/${TARGET}/release/makevn" ]]; then
  BIN_SOURCE_DIR="${ROOT_DIR}/target/${TARGET}/release"
else
  BIN_SOURCE_DIR="${ROOT_DIR}/target/release"
fi

for binary in makevn makevn-mcp; do
  if [[ ! -x "${BIN_SOURCE_DIR}/${binary}" ]]; then
    printf 'Error: expected executable %s\n' "${BIN_SOURCE_DIR}/${binary}" >&2
    exit 1
  fi
done

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}/bin" "${STAGE_DIR}/libexec/makevn" "${STAGE_DIR}/share/makevn"

cp "${BIN_SOURCE_DIR}/makevn" "${STAGE_DIR}/bin/makevn"
cp "${BIN_SOURCE_DIR}/makevn-mcp" "${STAGE_DIR}/bin/makevn-mcp"
cp "${ROOT_DIR}/libexec/makevn/cli.sh" "${STAGE_DIR}/libexec/makevn/cli.sh"
cp "${ROOT_DIR}/libexec/makevn/backend.sh" "${STAGE_DIR}/libexec/makevn/backend.sh"
cp "${ROOT_DIR}/libexec/makevn/common.sh" "${STAGE_DIR}/libexec/makevn/common.sh"
cp -R "${ROOT_DIR}/libexec/makevn/commands" "${STAGE_DIR}/libexec/makevn/commands"
cp -R "${ROOT_DIR}/libexec/makevn/common" "${STAGE_DIR}/libexec/makevn/common"
cp -R "${ROOT_DIR}/libexec/makevn/coverage" "${STAGE_DIR}/libexec/makevn/coverage"
cp -R "${ROOT_DIR}/libexec/makevn/docker" "${STAGE_DIR}/libexec/makevn/docker"
cp -R "${ROOT_DIR}/libexec/makevn/jdk" "${STAGE_DIR}/libexec/makevn/jdk"
cp -R "${ROOT_DIR}/libexec/makevn/compat" "${STAGE_DIR}/libexec/makevn/compat"
cp -R "${ROOT_DIR}/share/makevn/." "${STAGE_DIR}/share/makevn/"
mkdir -p "${STAGE_DIR}/share/makevn/skills/makevn"
cp -R "${ROOT_DIR}/skills/makevn/." "${STAGE_DIR}/share/makevn/skills/makevn/"

chmod +x "${STAGE_DIR}/bin/makevn" "${STAGE_DIR}/bin/makevn-mcp"
chmod +x "${STAGE_DIR}/libexec/makevn/cli.sh" "${STAGE_DIR}/libexec/makevn/backend.sh" "${STAGE_DIR}/libexec/makevn/common.sh"
find "${STAGE_DIR}/libexec/makevn" -type f -name '*.sh' -exec chmod +x {} +

mkdir -p "${DIST_ROOT}"
tar -C "${DIST_ROOT}" -czf "${ARCHIVE_PATH}" "$(basename "${STAGE_DIR}")"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "${DIST_ROOT}" && sha256sum "${ARCHIVE_NAME}" > "$(basename "${CHECKSUM_PATH}")")
else
  (cd "${DIST_ROOT}" && shasum -a 256 "${ARCHIVE_NAME}" > "$(basename "${CHECKSUM_PATH}")")
fi

printf 'Built runtime archive at %s\n' "${ARCHIVE_PATH}"
printf 'Built checksum at %s\n' "${CHECKSUM_PATH}"
