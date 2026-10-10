#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/libexec/makevn/common.sh"
tmp="$(mktemp -d)"
trap 'chmod -R u+w "${tmp}"; rm -rf "${tmp}"' EXIT
export MAKEVN_BACKEND_DETAIL_OUT="${tmp}/detail"
mkdir -p "${tmp}/.makevn/logs"
log="${tmp}/.makevn/logs/prepare.log"
printf 'old diagnostic\n' > "${log}"
chmod 444 "${log}"
MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged "${tmp}" prepare verify-changes prepare /bin/echo NEW > "${tmp}/output"
grep -q '^NEW$' "${log}"
grep -q 'old diagnostic' "${log}.previous"

makevn_test_process_preflight() { return 0; }
makevn_effective_java_home() { printf '/usr\n'; }
makevn_command_working_directory() { printf '%s\n' "$1"; }
MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${tmp}" code "${tmp}" prepare verify-changes prepare /bin/echo CONTEXT > "${tmp}/output"
grep -q '^CONTEXT$' "${log}"
grep -q '^NEW$' "${log}.previous"
makevn_write_quick_backend_log "${tmp}" prepare verify-changes prepare echo QUICK
grep -q '^QUICK$' "${log}"
grep -q '^CONTEXT$' "${log}.previous"

rm "${log}"
mkdir "${log}"
if MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged "${tmp}" prepare verify-changes prepare touch "${tmp}/command-started" > "${tmp}/output" 2>&1; then exit 1; fi
[[ ! -e "${tmp}/command-started" ]]
grep -q 'Command was not started' "${tmp}/output"
grep -q 'Cannot prepare log' "${MAKEVN_BACKEND_DETAIL_OUT}"
printf 'Log reuse and rotation regressions passed\n'
# Reject links and failed rotation without touching the old diagnostic or target.
rmdir "${log}"
printf 'external\n' > "${tmp}/external"
ln -s "${tmp}/external" "${log}"
if makevn_prepare_logfile "${log}" >/dev/null 2>&1; then exit 1; fi
grep -q '^external$' "${tmp}/external"
rm "${log}" "${log}.previous"
printf 'preserve\n' > "${log}"
mkdir "${log}.previous"
if makevn_prepare_logfile "${log}" >/dev/null 2>&1; then exit 1; fi
grep -q '^preserve$' "${log}"
[[ -z "$(find "${tmp}" -name '*.new.*' -print)" ]]
