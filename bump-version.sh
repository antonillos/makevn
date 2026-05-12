#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARGO_MANIFEST="${SCRIPT_DIR}/rust/dispatcher/Cargo.toml"
MCP_PACKAGE="${SCRIPT_DIR}/mcp/package.json"
TAP_FORMULA="${SCRIPT_DIR}/../homebrew-tap/Formula/makevn.rb"
PACKAGING_FORMULA="${SCRIPT_DIR}/packaging/homebrew/makevn.rb"

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

# Bump mcp/package.json to match (JS reference implementation)
if [[ -f "${MCP_PACKAGE}" ]]; then
  sed -i '' -E 's/"version": "[^"]+"/"version": "'"${VERSION}"'"/' "${MCP_PACKAGE}"
  printf '  ✔ Updated mcp/package.json\n'
fi


# Update Homebrew formula stable block if this looks like a release (not dev)
if ! echo "${VERSION}" | grep -qE '\-'; then
  tag="v${VERSION}"
  archive_url="https://github.com/antonillos/makevn/releases/download/${tag}/makevn-${tag}.tar.gz"

  for formula in "${TAP_FORMULA}" "${PACKAGING_FORMULA}"; do
    if [[ -f "${formula}" ]]; then
      sed -i '' -E 's|url ".*"|url "'"${archive_url}"'"|' "${formula}"
      sed -i '' -E 's/sha256 ".*"/sha256 "TBD_AFTER_RELEASE"/' "${formula}"
      printf '  ✔ Updated %s\n' "${formula}"
    fi
  done
  printf '\n⚠  Update the SHA-256 in the formula after the GitHub release is created.\n'
  printf '   Download the archive and run: shasum -a 256 <archive>\n'
fi

printf '\n✔ Bumped to %s\n' "${VERSION}"
printf '\nNext steps:\n'
printf '  1. git add -p && git commit -m "release: bump to %s"\n' "${VERSION}"
printf '  2. git tag v%s\n' "${VERSION}"
printf '  3. git push origin main --tags\n'
printf '  4. Run the release workflow on GitHub:\n'
printf '     gh workflow run release.yml -f version=v%s -f target_ref=main\n' "${VERSION}"
printf '  5. Update the Homebrew formula SHA-256\n'
printf '  6. Publish MCP server (optional): cd mcp && npm publish\n'
