#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common.sh"
source "${ROOT_DIR}/libexec/makevn/commands/karate.sh"
source "${ROOT_DIR}/libexec/makevn/commands/run.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/.github/workflows" "${tmp}/.makevn"
printf 'jobs:\n  karate:\n    env:\n      SPRING_PROFILES_ACTIVE: standalone,local\n' > "${tmp}/.github/workflows/karate.yml"
printf '# user config\n' > "${tmp}/.makevn/config"
makevn_resolve_karate_profiles "${tmp}"
[[ ${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES} == standalone,local ]]
[[ ${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE} == CI:* ]]
makevn_update_config_karate_profiles "${tmp}" 'configured,local'
makevn_resolve_karate_profiles "${tmp}"
[[ ${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES} == configured,local ]]
[[ ${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES_SOURCE} == config* ]]
SPRING_PROFILES_ACTIVE=override makevn_resolve_karate_profiles "${tmp}"
[[ ${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES} == override ]]
SPRING_PROFILES_ACTIVE='' makevn_resolve_karate_profiles "${tmp}"
[[ -z ${MAKEVN_EFFECTIVE_KARATE_APP_PROFILES} ]]
makevn_update_config_karate_profiles "${tmp}" 'replaced'
[[ $(grep -c '^MAKEVN_KARATE_APP_PROFILES=' "${tmp}/.makevn/config") == 1 ]]
grep -q '# user config' "${tmp}/.makevn/config"
# No TTY: doctor must never read a prompt or change config.
makevn_read_editable_default() { echo unexpected > "${tmp}/prompt"; return 1; }
cp "${tmp}/.makevn/config" "${tmp}/before"
makevn_doctor_karate_profiles "${tmp}" yes </dev/null 2>/dev/null
cmp "${tmp}/before" "${tmp}/.makevn/config"
[[ ! -e ${tmp}/prompt ]]
# Configured profiles apply only to the managed Karate application startup.
(
  makevn_detect_maven_base_path() { echo /fake/code; }
  makevn_detect_app_runnable() { return 0; }
  makevn_app_health_url() { echo http://localhost/health; }
  makevn_report_run_detail() { :; }
  cmd_karate_docker_up() { [[ -z ${SPRING_PROFILES_ACTIVE+x} ]]; }
  cmd_package() { :; }
  cmd_run_app_bg() { bash -c 'printf "%s\n" "$SPRING_PROFILES_ACTIVE"' > "${tmp}/active"; }
  cmd_docker_ps_required() { :; }
  cmd_karate_test() { [[ -z ${SPRING_PROFILES_ACTIVE+x} ]]; return 42; }
  cmd_stop_app() { echo stopped > "${tmp}/stopped"; }
  unset SPRING_PROFILES_ACTIVE
  if cmd_karate_all "${tmp}"; then exit 1; else [[ $? == 42 ]]; fi
  [[ $(cat "${tmp}/active") == replaced ]]
  [[ -f ${tmp}/stopped ]]
)
# Ambiguity and invalid explicit config must stop before Docker starts.
(
  unset MAKEVN_KARATE_APP_PROFILES SPRING_PROFILES_ACTIVE
  : > "${tmp}/.makevn/config"
  printf 'jobs:\n  karate:\n    env:\n      SPRING_PROFILES_ACTIVE: other\n' > "${tmp}/.github/workflows/karate-other.yml"
  makevn_doctor_karate_profiles "${tmp}" yes </dev/null 2>/dev/null
  [[ ${MAKEVN_DOCTOR_KARATE_APP_PROFILES} == 'unresolved (explicit selection required)' ]]
  makevn_detect_maven_base_path() { echo /fake/code; }
  makevn_detect_app_runnable() { return 0; }
  makevn_app_health_url() { echo http://localhost/health; }
  cmd_karate_docker_up() { touch "${tmp}/unexpected-docker"; }
  if (cmd_karate_all "${tmp}") > "${tmp}/failure" 2>&1; then exit 1; fi
  grep -q 'Ambiguous Karate Spring profiles' "${tmp}/failure"
  [[ ! -f ${tmp}/unexpected-docker ]]
  makevn_update_config_karate_profiles "${tmp}" 'bad profiles'
  if (cmd_karate_all "${tmp}") > "${tmp}/failure" 2>&1; then exit 1; fi
  grep -q 'Invalid MAKEVN_KARATE_APP_PROFILES' "${tmp}/failure"
  [[ ! -f ${tmp}/unexpected-docker ]]
)
printf 'Karate profiles shell tests passed\n'
