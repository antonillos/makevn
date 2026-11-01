#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/libexec/makevn/common.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/.makevn" "${tmp}/e2e"
printf 'services: {}\n' > "${tmp}/docker-compose.yml"
printf 'services: {}\n' > "${tmp}/e2e/docker-compose.yml"
makevn_write_config "${tmp}"
makevn_update_config_compose_file "${tmp}" none
makevn_update_config_e2e_compose_file "${tmp}" none
# Even a single discovered file and a persisted profile must not override none.
MAKEVN_PROFILE_COMPOSE_FILE="${tmp}/docker-compose.yml"
MAKEVN_PROFILE_E2E_COMPOSE_FILE="${tmp}/e2e/docker-compose.yml"
! makevn_boot_compose_file_path "${tmp}"
! makevn_karate_compose_file_path "${tmp}"
[[ "$(makevn_boot_compose_resolution_error "${tmp}")" == *disabled* ]]
makevn_update_config_compose_file "${tmp}" "${tmp}/docker-compose.yml"
[[ "$(makevn_boot_compose_file_path "${tmp}")" == "${tmp}/docker-compose.yml" ]]
source "${ROOT}/libexec/makevn/commands/maven.sh"
makevn_verify_requires_boot_docker() {
  makevn_load_config "$1"
  [[ "${MAKEVN_COMPOSE_FILE}" == none ]] || return 99
  return 1
}
makevn_run_maven_goal() {
  makevn_load_config "$1"
  [[ "${MAKEVN_COMPOSE_FILE}" == none ]]
  [[ "$*" != *--compose-file* ]]
}
makevn_effective_local_containers() { :; }
MAKEVN_EXECUTION_COMPOSE_FILE=none cmd_verify "${tmp}"
[[ "$(makevn_boot_compose_file_path "${tmp}")" == "${tmp}/docker-compose.yml" ]]
mkdir "${tmp}/bin"
cat > "${tmp}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_TEST_LOG}"
case "$1" in
  compose) printf 'selected-container\n' ;;
  inspect) printf 'running\n' ;;
esac
MOCK
chmod +x "${tmp}/bin/docker"
export DOCKER_TEST_LOG="${tmp}/calls"
PATH="${tmp}/bin:/usr/bin:/bin" MAKEVN_EXECUTION_COMPOSE_FILE="${tmp}/custom compose.yaml" bash "${ROOT}/libexec/makevn/docker/stats.sh"
[[ "$(cat "${DOCKER_TEST_LOG}")" == *selected-container* ]]
! PATH="${tmp}/bin:/usr/bin:/bin" MAKEVN_EXECUTION_COMPOSE_FILE=none bash "${ROOT}/libexec/makevn/docker/stats.sh"
