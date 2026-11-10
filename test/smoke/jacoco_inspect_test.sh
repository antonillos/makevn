#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="${ROOT_DIR}/libexec/makevn"
source "${SCRIPT_DIR}/commands/jacoco_inspect.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/makevn-jacoco-test.XXXXXXXX")"
trap 'rm -rf "${fixture}"' EXIT
makevn_die() { printf '%s\n' "$1" >&2; exit 1; }
makevn_detect_maven_base_path() { printf '%s\n' "${fixture}"; }
makevn_maven_executable() { printf '%s\n' fake-maven; }
makevn_maven_cli_flags_for_command() { printf '%s\n' "${MOCK_CLI:--B}"; }
makevn_maven_prop_flags_for_command() { printf '%s\n' "${MOCK_PROPS:-}"; }
makevn_coverage_prop_flags() { printf '%s\n' "${MOCK_COVERAGE:--Djacoco.skip=false}"; }
makevn_coverage_cli_flags() { printf '%s\n' ''; }
makevn_run_logged_in_context() {
  [[ "${FAIL_MODEL:-0}" != 1 ]] || return 42
  local argument output=''
  for argument in "$@"; do
    case "${argument}" in -Doutput=*) output="${argument#-Doutput=}" ;; esac
  done
  [[ -n "${output}" ]] || return 1
  printf '%s\n' "${output}" > "${fixture}/output-path"
  cat > "${output}" <<'XML'
<project><artifactId>fixture</artifactId><properties><fixture.secret>not-for-output</fixture.secret></properties><build><plugins><plugin><groupId>org.jacoco</groupId><artifactId>jacoco-maven-plugin</artifactId><executions><execution><goals><goal>prepare-agent</goal></goals></execution></executions></plugin></plugins></build></project>
XML
}
output="$(cmd_jacoco_inspect "${fixture}")"
[[ "${output}" == *'"status": "configured"'* ]]
[[ "${output}" != *not-for-output* ]]
[[ ! -e "$(cat "${fixture}/output-path")" ]]
output="$(MOCK_COVERAGE='-D jacoco.skip=true' cmd_jacoco_inspect "${fixture}")"
[[ "${output}" == *'"status": "absent"'* ]]
output="$(MOCK_COVERAGE='--define=jacoco.skip=true' cmd_jacoco_inspect "${fixture}")"
[[ "${output}" == *'"status": "absent"'* ]]
output="$(MOCK_PROPS='-Djacoco.skip=true' MOCK_COVERAGE='-Djacoco.skip=false' cmd_jacoco_inspect "${fixture}")"
[[ "${output}" == *'"status": "configured"'* ]]
output="$(MOCK_CLI='--define jacoco.skip=true' MOCK_COVERAGE='-Dcustom=true' cmd_jacoco_inspect "${fixture}")"
[[ "${output}" == *'"status": "absent"'* ]]
rc=0
FAIL_MODEL=1 cmd_jacoco_inspect "${fixture}" > "${fixture}/failed" 2>&1 || rc=$?
[[ "${rc}" == 42 ]]
[[ "$(cat "${fixture}/failed")" == *'JaCoCo model: unknown'* ]]
rc=0
cmd_jacoco_inspect "${fixture}" --unexpected > "${fixture}/invalid" 2>&1 || rc=$?
[[ "${rc}" == 1 ]]
