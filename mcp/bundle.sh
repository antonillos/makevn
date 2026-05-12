#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DATE="0.1.0-dev-$(date +%Y.%m.%d.%H.%M)"

esbuild "${SCRIPT_DIR}/src/index.ts" \
  --bundle \
  --platform=node \
  --outfile="${SCRIPT_DIR}/dist/makevn-mcp.js" \
  --banner:js='#!/usr/bin/env node' \
  --format=esm \
  --define:__BUILD_DATE="\"${BUILD_DATE}\""

chmod +x "${SCRIPT_DIR}/dist/makevn-mcp.js"

printf 'Built %s\n' "${SCRIPT_DIR}/dist/makevn-mcp.js"
printf 'Version: %s\n' "${BUILD_DATE}"
