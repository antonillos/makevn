#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/libexec/makevn/common.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir "${tmp}/.makevn"
makevn_write_config "${tmp}"
# Simulate a CLI installation without Python while retaining basic shell tools.
command() {
  [[ "$*" != '-v python3' ]] || return 1
  builtin command "$@"
}
makevn_validate_doctor_setting app_health_url 'http://localhost/health'
! makevn_validate_doctor_setting app_health_url 'file:///health'
makevn_validate_doctor_setting karate_app_profiles 'standalone,local'
! makevn_validate_doctor_setting karate_app_profiles '${DYNAMIC}'
! makevn_validate_doctor_setting unknown value
! makevn_update_config_setting "${tmp}/missing" MAKEVN_APP_HEALTH_URL value
url='http://localhost/health?literal=$(false)&quote="value"'
makevn_update_config_app_health_url "${tmp}" "${url}"
makevn_update_config_compose_file "${tmp}" '/compose/with spaces.yml'
makevn_update_config_e2e_compose_file "${tmp}" '/e2e/with spaces.yml'
makevn_update_config_local_containers "${tmp}" ''
makevn_update_config_karate_profiles "${tmp}" 'standalone,local'
makevn_load_config "${tmp}"
[[ "${MAKEVN_APP_HEALTH_URL}" == "${url}" ]]
[[ "${MAKEVN_COMPOSE_FILE}" == '/compose/with spaces.yml' ]]
[[ "${MAKEVN_E2E_COMPOSE_FILE}" == '/e2e/with spaces.yml' ]]
[[ -z "${MAKEVN_LOCAL_CONTAINERS}" ]]
[[ "${MAKEVN_KARATE_APP_PROFILES}" == standalone,local ]]
makevn_doctor_collect_setup "${tmp}"
[[ "${MAKEVN_DOCTOR_SETUP_DETAILS}" == *'"available": false'* ]]
printf 'Doctor CLI setup without Python passed\n'
