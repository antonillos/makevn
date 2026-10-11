#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="${ROOT}/libexec/makevn"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/commands/init.sh"
source "${SCRIPT_DIR}/commands/doctor.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/workspace/first" "${tmp}/workspace/second"
printf '<project><packaging>pom</packaging><modules><module>first</module></modules></project>' > "${tmp}/workspace/pom.xml"
printf '<project/>' > "${tmp}/workspace/first/pom.xml"
printf '<project/>' > "${tmp}/workspace/second/pom.xml"
print_command_intro() { :; }
# Isolate orchestration from environment setup: never Maven/JDK/Docker.
makevn_detect_maven_base_path() { printf '%s/workspace\n' "$1"; }
makevn_start_state_phase() { :; }
makevn_write_config() { touch "$1/.makevn/config"; }
makevn_refresh_profile() { :; }
makevn_update_config_generated_contract_clean_dirs() { :; }
makevn_write_state_json() { :; }
makevn_write_manifest() { touch "$1/.makevn/manifest"; }
cmd_init "${tmp}" --dry-run > "${tmp}/dry-run"
[[ ! -e "${tmp}/.makevn/impact.json" ]]
cmd_init "${tmp}" > "${tmp}/init"
[[ -f "${tmp}/.makevn/impact.json" && ! -e "${tmp}/makevn-impact.json" ]]
grep -q 'all-reactor-suites' "${tmp}/.makevn/impact.json"
grep -q 'Impact analysis' "${tmp}/init"
printf '<project><packaging>pom</packaging><modules><module>second</module></modules></project>' > "${tmp}/workspace/pom.xml"
cmd_init "${tmp}" --dry-run > "${tmp}/existing-dry-run"
grep -q 'first' "${tmp}/.makevn/impact.json"
cmd_init "${tmp}" > "${tmp}/existing-init"
grep -q 'second' "${tmp}/.makevn/impact.json"
! grep -q 'first' "${tmp}/.makevn/impact.json"
printf '<project><packaging>pom</packaging><modules><module>first</module></modules></project>' > "${tmp}/workspace/pom.xml"
makevn_collect_doctor_snapshot() {
  MAKEVN_DOCTOR_MAVEN_BASE_PATH="${tmp}/workspace"
  MAKEVN_DOCTOR_BUILD_STATUS=current
  MAKEVN_DOCTOR_TEST_PROCESSES=unavailable
  MAKEVN_DOCTOR_BIND_MOUNTS=unavailable
  MAKEVN_DOCTOR_CURRENT_STATUS=initialized
  MAKEVN_DOCTOR_REPO_SUPPORT_STATUS=supported
}
makevn_doctor_progress() { :; }
makevn_print_doctor_init_recommendation() { :; }
makevn_print_doctor_suggestions() { :; }
print_doctor "${tmp}" --compact > "${tmp}/doctor"
grep -q 'first' "${tmp}/.makevn/impact.json"
! grep -q 'second' "${tmp}/.makevn/impact.json"
grep -q 'external/E2E and global gates not evaluated' "${tmp}/doctor"
# Adoption stays independent of Python, with visible deferred analysis.
mkdir -p "${tmp}/no-python" "${tmp}/empty-path"
(PATH="${tmp}/empty-path"; makevn_refresh_impact "${tmp}/no-python") > "${tmp}/deferred"
grep -q 'deferred: Python 3' "${tmp}/deferred"
[[ ! -e "${tmp}/no-python/.makevn" ]]
# Unsupported repositories do not create state.
makevn_detect_maven_base_path() { :; }
mkdir "${tmp}/unsupported"
makevn_refresh_impact "${tmp}/unsupported"
[[ ! -e "${tmp}/unsupported/.makevn" ]]
printf 'Generated impact init/doctor orchestration passed\n'
