#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: build-source-archive.sh <version> [dist-dir]}"
DIST_DIR="${2:-dist}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)"
if [[ "${DIST_DIR}" = /* ]]; then
  DIST_ROOT="${DIST_DIR}"
else
  DIST_ROOT="${ROOT_DIR}/${DIST_DIR}"
fi
ARCHIVE_NAME="makevn-${VERSION}.tar.gz"
ARCHIVE_PATH="${DIST_ROOT}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
PREFIX="makevn-${VERSION#v}/"

mkdir -p "${DIST_ROOT}"

git -C "${ROOT_DIR}" archive \
  --format=tar.gz \
  --prefix="${PREFIX}" \
  -o "${ARCHIVE_PATH}" \
  HEAD

if command -v sha256sum >/dev/null 2>&1; then
  (cd "${DIST_ROOT}" && sha256sum "${ARCHIVE_NAME}" > "$(basename "${CHECKSUM_PATH}")")
else
  (cd "${DIST_ROOT}" && shasum -a 256 "${ARCHIVE_NAME}" > "$(basename "${CHECKSUM_PATH}")")
fi

printf 'Built source archive at %s\n' "${ARCHIVE_PATH}"
printf 'Built checksum at %s\n' "${CHECKSUM_PATH}"
