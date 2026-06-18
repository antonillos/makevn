#!/usr/bin/env bash
set -euo pipefail

MAKEVN_LIBEXEC_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKEVN_INSTALL_ROOT="${MAKEVN_INSTALL_ROOT:-$(CDPATH= cd -- "${MAKEVN_LIBEXEC_DIR}/../.." && pwd)}"
MAKEVN_BIN_PATH="${MAKEVN_BIN_PATH:-${MAKEVN_INSTALL_ROOT}/bin/makevn}"
if [[ -f "${MAKEVN_LIBEXEC_DIR}/version.env" ]]; then
  # shellcheck source=/dev/null
  source "${MAKEVN_LIBEXEC_DIR}/version.env"
fi
MAKEVN_VERSION="${MAKEVN_VERSION:-0.1.0-dev}"
MAKEVN_BLOCK_BEGIN="# makevn:begin"
MAKEVN_BLOCK_END="# makevn:end"

# shellcheck source=/dev/null
source "${MAKEVN_LIBEXEC_DIR}/common/ui.sh"
# shellcheck source=/dev/null
source "${MAKEVN_LIBEXEC_DIR}/common/core.sh"
# shellcheck source=/dev/null
source "${MAKEVN_LIBEXEC_DIR}/common/backend_logging.sh"
# shellcheck source=/dev/null
source "${MAKEVN_LIBEXEC_DIR}/common/doctor_snapshot.sh"
# shellcheck source=/dev/null
source "${MAKEVN_LIBEXEC_DIR}/common/profile_detection.sh"
# shellcheck source=/dev/null
source "${MAKEVN_LIBEXEC_DIR}/common/java_maven.sh"
# shellcheck source=/dev/null
source "${MAKEVN_LIBEXEC_DIR}/common/state_files.sh"
# shellcheck source=/dev/null
source "${MAKEVN_LIBEXEC_DIR}/common/generated_contract.sh"
