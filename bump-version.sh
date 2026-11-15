#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARGO_MANIFEST="${SCRIPT_DIR}/rust/dispatcher/Cargo.toml"

usage() {
  cat <<EOF
Usage: ./bump-version.sh <version>

Examples:
  ./bump-version.sh 0.2.0          # bump to 0.2.0 (dev)
  ./bump-version.sh 0.1.0          # bump to 0.1.0 (release)
EOF
  exit 1
}

VERSION="${1:-}"
[[ -n "${VERSION}" ]] || usage

# Validate version format
if ! echo "${VERSION}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'; then
  printf 'Error: version must match semver (e.g. 0.1.0 or 0.2.0-dev)\n' >&2
  exit 1
fi

# Current version
current_version="$(sed -nE 's/^version = "([^"]+)"/\1/p' "${CARGO_MANIFEST}" | head -n 1)"
printf 'Current makevn version: %s\n' "${current_version}"
printf 'New makevn version:     %s\n' "${VERSION}"

# Bump Cargo.toml
sed -i '' -E 's/^version = "[^"]+"/version = "'"${VERSION}"'"/' "${CARGO_MANIFEST}"
printf '  ✔ Updated Cargo.toml\n'

printf '\n✔ Bumped to %s\n' "${VERSION}"
printf '\nNext steps:\n'
printf '  1. git add -p && git commit -m "release: bump to %s"\n' "${VERSION}"
printf '  2. git tag v%s\n' "${VERSION}"
printf '  3. git push origin main --tags\n'
printf '  4. Run the release workflow on GitHub:\n'
printf '     gh workflow run release.yml -f version=v%s -f target_ref=main\n' "${VERSION}"
printf '  5. The release workflow updates Homebrew URLs and checksums.\n'
