#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/project with spaces"
export MAKEVN_EXECUTION_COMPOSE_FILE="${tmp}/project with spaces/compose.yaml"
printf 'services: {}\n' > "${MAKEVN_EXECUTION_COMPOSE_FILE}"
export DOCKER_TEST_LOG="${tmp}/calls"
cat > "${tmp}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '<%s>' "$@" >> "${DOCKER_TEST_LOG}"
printf '\n' >> "${DOCKER_TEST_LOG}"
case "$1" in
  compose) printf 'selected-container\n' ;;
  inspect) printf 'running\n' ;;
esac
MOCK
chmod +x "${tmp}/bin/docker"
for with_override in false true; do
  expected="<compose><-f><${MAKEVN_EXECUTION_COMPOSE_FILE}>"
  if [[ "${with_override}" == true ]]; then
    override="${tmp}/project with spaces/docker-compose.override.yml"
    printf 'name: override-project\nservices: {}\n' > "${override}"
    expected+="<-f><${override}>"
  fi
  for diagnostic in ps stats; do
    : > "${DOCKER_TEST_LOG}"
    PATH="${tmp}/bin:/usr/bin:/bin" bash "${ROOT}/libexec/makevn/docker/${diagnostic}.sh" > /dev/null
    IFS= read -r actual < "${DOCKER_TEST_LOG}"
    suffix='<ps><-aq>'
    [[ "${diagnostic}" != stats ]] || suffix='<ps><-q>'
    [[ "${actual}" == "${expected}${suffix}" ]]
  done
  : > "${DOCKER_TEST_LOG}"
  PATH="${tmp}/bin:/usr/bin:/bin" COMPOSE_ARGS=selected SERVICES=web bash "${ROOT}/libexec/makevn/docker/ps.sh" > /dev/null
  IFS= read -r actual < "${DOCKER_TEST_LOG}"
  [[ "${actual}" == "${expected}<ps><-q><web>" ]]
done
printf 'Scoped Compose diagnostics tests passed\n'
