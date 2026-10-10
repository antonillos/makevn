#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/libexec/makevn/common.sh"
MAKEVN_DOCTOR_COMPOSE_FILE='resolved'
MAKEVN_DOCTOR_E2E_COMPOSE_FILE='resolved'
MAKEVN_DOCTOR_APP_RUNNABLE=yes
MAKEVN_APP_HEALTH_URL='http://localhost/health'
verify_it_local_containers_default=''
MAKEVN_DOCTOR_KARATE_APP_PROFILES='unresolved (explicit selection required)'
unset SPRING_PROFILES_ACTIVE MAKEVN_KARATE_APP_PROFILES
makevn_doctor_interactive_setup_status
[[ "${MAKEVN_DOCTOR_INTERACTIVE_REQUIRED}" == true ]]
MAKEVN_KARATE_APP_PROFILES='standalone,local'
makevn_doctor_interactive_setup_status
[[ "${MAKEVN_DOCTOR_INTERACTIVE_REQUIRED}" == false ]]
unset MAKEVN_KARATE_APP_PROFILES
SPRING_PROFILES_ACTIVE=''
makevn_doctor_interactive_setup_status
[[ "${MAKEVN_DOCTOR_INTERACTIVE_REQUIRED}" == false ]]
unset SPRING_PROFILES_ACTIVE
MAKEVN_DOCTOR_KARATE_APP_PROFILES='standalone,local'
makevn_doctor_interactive_setup_status
[[ "${MAKEVN_DOCTOR_INTERACTIVE_REQUIRED}" == false ]]
printf 'Doctor pending profile questions tests passed\n'
MAKEVN_DOCTOR_INTERACTIVE_REQUIRED=true
MAKEVN_COMPACT_OUTPUT=1
makevn_doctor_interaction_status
[[ "${MAKEVN_DOCTOR_SETUP_STATUS}" == pending ]]
[[ "${MAKEVN_DOCTOR_INTERACTION_BLOCKERS}" == *compact_mode* ]]
[[ -t 0 ]] || [[ "${MAKEVN_DOCTOR_INTERACTION_BLOCKERS}" == *stdin_not_tty* ]]
[[ -t 2 ]] || [[ "${MAKEVN_DOCTOR_INTERACTION_BLOCKERS}" == *stderr_not_tty* ]]
MAKEVN_DOCTOR_INTERACTIVE_REQUIRED=false
makevn_doctor_interaction_status
[[ "${MAKEVN_DOCTOR_SETUP_STATUS}" == ready && -z "${MAKEVN_DOCTOR_INTERACTION_BLOCKERS}" ]]
# Saved answers must refresh the final verdict without a second doctor run.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir "${tmp}/.makevn"
makevn_write_config "${tmp}"
MAKEVN_APP_HEALTH_URL=''
local_containers_configured=no
verify_it_local_containers_default=TRUE
MAKEVN_DOCTOR_KARATE_APP_PROFILES='standalone,local'
makevn_update_config_app_health_url "${tmp}" 'http://localhost/health'
for preference in TRUE ''; do
  makevn_update_config_local_containers "${tmp}" "${preference}"
  MAKEVN_APP_HEALTH_URL=''
  local_containers_configured=no
  makevn_doctor_refresh_setup_answers "${tmp}"
  makevn_doctor_interactive_setup_status
  [[ "${MAKEVN_APP_HEALTH_URL}" == 'http://localhost/health' ]]
  [[ "${local_containers_configured}" == yes ]]
  [[ "${MAKEVN_DOCTOR_INTERACTIVE_REQUIRED}" == false ]]
done
