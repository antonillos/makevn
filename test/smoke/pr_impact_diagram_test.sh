#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="${ROOT}/libexec/makevn"
source "${SCRIPT_DIR}/commands/focused_changes.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
makevn_state_dir() { printf '%s/.makevn\n' "$1"; }
makevn_print_detail_line() { printf '%s\n' "$1"; }
makevn_die() { printf '%s\n' "$1" >&2; exit 1; }
makevn_changes_mode --diagram --base HEAD
[[ "${MAKEVN_VERIFY_CHANGES_MODE_ARGS}" == 3 ]]
MAKEVN_VERIFY_CHANGES_PARENT_SPEC=HEAD
MAKEVN_VERIFY_CHANGES_INPUTS=$'src/main/java/Price.java\nsrc/test/resources/prices.csv'
MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN=$'.\texample.PriceTest'
MAKEVN_VERIFY_CHANGES_MODULE_SELECTION=.
output="$(makevn_print_pr_impact_diagram "${tmp}")"
[[ "${output}" == *"PR diagram:"* ]]
artifact="${tmp}/.makevn/reports/verify-changes/impact.md"
[[ -f "${artifact}" ]]
grep -Fq 'Changed files: 2' "${artifact}"
grep -Fq 'PriceTest' "${artifact}"
cp "${artifact}" "${tmp}/expected.md"
rm "${artifact}"
MAKEVN_MCP_INSPECTION=1
output="$(makevn_print_pr_impact_diagram "${tmp}")"
[[ ! -f "${artifact}" ]]
python3 - "${output#MAKEVN_PR_DIAGRAM_JSON=}" "${tmp}/expected.md" <<'PY'
import json
from pathlib import Path
import sys
assert json.loads(sys.argv[1])['markdown'] == Path(sys.argv[2]).read_text()
PY
MAKEVN_VERIFY_CHANGES_INPUTS="$(python3 -c 'print("\n".join("module/src/main/java/example/LongProductionClassName" + str(i) + ".java" for i in range(3000)))')"
MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN="$(python3 -c 'print("\n".join("module-with-a-long-name-for-large-reactor-testing-" + str(i) + "\texample.LongProductionClassNameTest" + str(i) for i in range(3000)))')"
MAKEVN_VERIFY_CHANGES_MODULE_SELECTION="$(python3 -c 'print(",".join("module-with-a-long-name-for-large-reactor-testing-" + str(i) for i in range(3000)))')"
# Enforce a small per-argument bound even on hosts without Linux's 128 KiB limit.
python3() {
  local argument
  for argument in "$@"; do
    [[ ${#argument} -lt 4096 ]] || { printf 'Unbounded diagram argument\n' >&2; return 1; }
  done
  command python3 "$@"
}
output="$(makevn_print_pr_impact_diagram "${tmp}")"
python3 - "${output#MAKEVN_PR_DIAGRAM_JSON=}" <<'PYTHON'
import json
import sys
result = json.loads(sys.argv[1])
assert result['changedInputs'] == 3000
assert result['selectedModules'] == 3000
assert result['groupedModules'] == 2996
assert len(result['markdown']) < 2500
PYTHON
[[ ! -f "${artifact}" ]]
MAKEVN_MCP_INSPECTION=''
makevn_print_pr_impact_diagram "${tmp}" >/dev/null
grep -Fq 'Changed files: 3000' "${artifact}"
grep -Fq '2996 additional modules' "${artifact}"
MAKEVN_MCP_INSPECTION=1
MAKEVN_VERIFY_CHANGES_MODE=exhaustive
output="$(makevn_print_pr_impact_diagram "${tmp}")"
[[ "${output}" == *'"selectedModules": 3000'* ]]
MAKEVN_VERIFY_CHANGES_MODE=focused
MAKEVN_VERIFY_CHANGES_SCOPE_REQUIRED=true
output="$(makevn_print_pr_impact_diagram "${tmp}")"
[[ "${output}" == *'requires_exhaustive'* ]]
makevn_changes_mode
[[ "${MAKEVN_CHANGES_DIAGRAM}" == false ]]
[[ -z "$(makevn_print_pr_impact_diagram "${tmp}")" ]]
printf 'PR diagram shell tests passed\n'
