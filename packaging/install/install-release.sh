#!/usr/bin/env sh
set -eu

OWNER_REPO="${MAKEVN_REPO:-antonillos/makevn}"
VERSION="${MAKEVN_VERSION:-latest}"
PREFIX="${PREFIX:-$HOME/.local}"
TMPDIR_ROOT="${TMPDIR:-/tmp}"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

detect_target() {
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Linux) os_part="unknown-linux-gnu" ;;
    Darwin) os_part="apple-darwin" ;;
    *) fail "unsupported OS: $os" ;;
  esac

  case "$os:$arch" in
    Linux:x86_64|Linux:amd64) arch_part="x86_64" ;;
    Darwin:x86_64|Darwin:amd64) arch_part="x86_64" ;;
    Darwin:arm64|Darwin:aarch64) arch_part="aarch64" ;;
    Linux:arm64|Linux:aarch64) fail "Linux arm64 release assets are not published yet" ;;
    *) fail "unsupported platform: $os $arch" ;;
  esac

  printf '%s-%s\n' "$arch_part" "$os_part"
}

resolve_version() {
  if [ "$VERSION" != "latest" ]; then
    case "$VERSION" in
      v*) printf '%s\n' "$VERSION" ;;
      *) printf 'v%s\n' "$VERSION" ;;
    esac
    return 0
  fi

  need curl
  curl -fsSL "https://api.github.com/repos/${OWNER_REPO}/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | sed -n '1p'
}

checksum_file_contains_archive() {
  checksum_file="$1"
  archive_name="$2"
  if grep " ${archive_name}$" "$checksum_file" >/dev/null 2>&1; then
    return 0
  fi
  if grep "\*${archive_name}$" "$checksum_file" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

verify_checksum() {
  archive="$1"
  checksum="$2"
  archive_name="$(basename "$archive")"

  if command -v sha256sum >/dev/null 2>&1; then
    if checksum_file_contains_archive "$checksum" "$archive_name"; then
      (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$checksum")")
    else
      expected="$(sed -n 's/^\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' "$checksum" | sed -n '1p')"
      actual="$(sha256sum "$archive" | awk '{print $1}')"
      [ "$expected" = "$actual" ] || fail "checksum mismatch for $archive_name"
    fi
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    expected="$(sed -n 's/^\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' "$checksum" | sed -n '1p')"
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || fail "checksum mismatch for $archive_name"
    return 0
  fi

  fail "sha256sum or shasum is required"
}

need curl
need tar
TARGET="$(detect_target)"
TAG="$(resolve_version)"
[ -n "$TAG" ] || fail "could not resolve makevn release version"

ASSET="makevn-${TAG}-${TARGET}.tar.gz"
BASE_URL="https://github.com/${OWNER_REPO}/releases/download/${TAG}"
WORK_DIR="$(mktemp -d "${TMPDIR_ROOT}/makevn-install.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

log "Installing makevn ${TAG} for ${TARGET} into ${PREFIX}"
curl -fsSL "${BASE_URL}/${ASSET}" -o "${WORK_DIR}/${ASSET}"
curl -fsSL "${BASE_URL}/${ASSET}.sha256" -o "${WORK_DIR}/${ASSET}.sha256"
verify_checksum "${WORK_DIR}/${ASSET}" "${WORK_DIR}/${ASSET}.sha256"

tar -xzf "${WORK_DIR}/${ASSET}" -C "${WORK_DIR}"
EXTRACTED_DIR="$(find "${WORK_DIR}" -mindepth 1 -maxdepth 1 -type d | sed -n '1p')"
[ -n "$EXTRACTED_DIR" ] || fail "release archive did not contain an install directory"

mkdir -p "${PREFIX}/bin" "${PREFIX}/libexec" "${PREFIX}/share"
cp "${EXTRACTED_DIR}/bin/makevn" "${PREFIX}/bin/makevn"
cp "${EXTRACTED_DIR}/bin/makevn-mcp" "${PREFIX}/bin/makevn-mcp"
rm -rf "${PREFIX}/libexec/makevn" "${PREFIX}/share/makevn"
cp -R "${EXTRACTED_DIR}/libexec/makevn" "${PREFIX}/libexec/makevn"
cp -R "${EXTRACTED_DIR}/share/makevn" "${PREFIX}/share/makevn"
chmod +x "${PREFIX}/bin/makevn" "${PREFIX}/bin/makevn-mcp"

log "Installed makevn to ${PREFIX}"
log "Add ${PREFIX}/bin to PATH if needed."
"${PREFIX}/bin/makevn" --version >/dev/null
