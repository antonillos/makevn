#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: build-source-archive.sh <version> [dist-dir]}"
DIST_DIR="${2:-dist}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)"
ARCHIVE_NAME="makevn-${VERSION}.tar.gz"
ARCHIVE_PATH="${DIST_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
PREFIX="makevn-${VERSION#v}/"

mkdir -p "${ROOT_DIR}/${DIST_DIR}"

git -C "${ROOT_DIR}" archive \
  --format=tar.gz \
  --prefix="${PREFIX}" \
  -o "${ROOT_DIR}/${ARCHIVE_PATH}" \
  HEAD

if command -v sha256sum >/dev/null 2>&1; then
  (cd "${ROOT_DIR}/${DIST_DIR}" && sha256sum "${ARCHIVE_NAME}" > "$(basename "${CHECKSUM_PATH}")")
else
  (cd "${ROOT_DIR}/${DIST_DIR}" && shasum -a 256 "${ARCHIVE_NAME}" > "$(basename "${CHECKSUM_PATH}")")
fi

printf 'Built source archive at %s\n' "${ROOT_DIR}/${ARCHIVE_PATH}"
printf 'Built checksum at %s\n' "${ROOT_DIR}/${CHECKSUM_PATH}"
