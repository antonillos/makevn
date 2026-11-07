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
  inspect)
    case "$3" in
      *State.Status*) printf 'running\n' ;;
      *State.ExitCode*) printf '0\n' ;;
      *) printf 'healthy\n' ;;
    esac
    ;;
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
  [[ "${actual}" == "${expected}<ps><-aq><web>" ]]
done
cat > "${tmp}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  compose) printf 'stopped-container\n' ;;
  inspect)
    case "$3" in
      *State.Status*) printf 'exited\n' ;;
      *State.ExitCode*) printf '2\n' ;;
      *) printf 'unhealthy\n' ;;
    esac
    ;;
  logs) printf 'startup failure\n' ;;
esac
MOCK
chmod +x "${tmp}/bin/docker"
failure="$(PATH="${tmp}/bin:/usr/bin:/bin" COMPOSE_ARGS=selected SERVICES=web bash "${ROOT}/libexec/makevn/docker/ps.sh")"
[[ "${failure}" == *'web                          exited'* ]]
[[ "${failure}" == *'exit_code=2'* ]]
[[ "${failure}" == *'startup failure'* ]]
mkdir -p "${tmp}/linked-source" "${tmp}/repository"
printf 'services: {}\n' > "${tmp}/linked-source/docker-compose.yml"
ln -s "${tmp}/linked-source" "${tmp}/repository/e2e"
ln -s "${tmp}/linked-source" "${tmp}/repository/karate"
discovered="$(python3 "${ROOT}/libexec/makevn/common/compose_discovery.py" "${tmp}/repository" e2e)"
[[ "${discovered}" == "${tmp}/repository/e2e/docker-compose.yml" ]]
ln -s "${tmp}/missing" "${tmp}/repository/broken"
python3 "${ROOT}/libexec/makevn/common/compose_discovery.py" "${tmp}/repository" boot 2> "${tmp}/discovery-error" > /dev/null
grep -Fq 'Broken Compose link:' "${tmp}/discovery-error"
printf 'Scoped Compose diagnostics tests passed\n'
