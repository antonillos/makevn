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
