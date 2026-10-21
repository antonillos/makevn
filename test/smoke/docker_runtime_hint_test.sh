#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common/backend_logging.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
export MAKEVN_BACKEND_DETAIL_OUT="${TMP}/details"
export MAKEVN_FRONTEND=rust MAKEVN_FRONTEND_OWNS_LOADER=1

check_hint() {
  local message="$1" expected="$2"
  printf '%s\n' "${message}" > "${TMP}/docker.log"
  printf 'Existing detail\n' > "${MAKEVN_BACKEND_DETAIL_OUT}"
  makevn_report_docker_runtime_failure docker-up "${TMP}/docker.log"
  grep -Fq "${expected}" "${TMP}/docker.log"
  grep -Fq "${expected}" "${MAKEVN_BACKEND_DETAIL_OUT}"
  grep -Fq 'Existing detail' "${MAKEVN_BACKEND_DETAIL_OUT}"
  grep -Fq 'report the environment blocker' "${MAKEVN_BACKEND_DETAIL_OUT}"
  ! grep -Eq 'colima start|docker info|Docker context' "${MAKEVN_BACKEND_DETAIL_OUT}"
}
check_hint 'failed to connect to the docker API at unix:///Users/test/.colima/default/docker.sock: no such file' "makevn doctor"
check_hint 'Cannot connect to the Docker daemon at unix:///Users/test/.colima/work/docker.sock. Is the docker daemon running?' 'makevn doctor'
check_hint 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' 'makevn doctor'
! grep -Fq 'colima start' "${TMP}/docker.log"
check_hint 'error during connect: connection refused' 'makevn doctor'

for message in 'compose service exited with code 1' 'permission denied pulling image'; do
  printf '%s\n' "${message}" > "${TMP}/docker.log"
  : > "${MAKEVN_BACKEND_DETAIL_OUT}"
  makevn_report_docker_runtime_failure docker-up "${TMP}/docker.log"
  [[ ! -s "${MAKEVN_BACKEND_DETAIL_OUT}" ]]
  ! grep -Fq 'Hint:' "${TMP}/docker.log"
done
printf 'Cannot connect to the Docker daemon\n' > "${TMP}/docker.log"
makevn_report_docker_runtime_failure test "${TMP}/docker.log"
! grep -Fq 'Hint:' "${TMP}/docker.log"
unset MAKEVN_FRONTEND MAKEVN_FRONTEND_OWNS_LOADER
makevn_report_docker_runtime_failure karate-docker-up "${TMP}/docker.log" 2> "${TMP}/stderr"
grep -Fq 'makevn doctor' "${TMP}/stderr"
printf 'Docker runtime hint tests passed\n'

# The public managed-log path keeps the failing status and publishes the hint
# even without the interactive Rust frontend. No real engine is contacted.
source "${ROOT_DIR}/libexec/makevn/common.sh"
export MAKEVN_COMPACT_OUTPUT=1
unset MAKEVN_TRACE_OUTPUT
set +e
(makevn_run_logged "${TMP}" docker-up docker-up docker-up bash -c   'printf "failed to connect to the docker API at unix:///Users/test/.colima/default/docker.sock\n" >&2; exit 7') > "${TMP}/output" 2>&1
status=$?
set -e
[[ ${status} -eq 7 ]]
grep -Fq "makevn doctor" "${TMP}/output"
grep -Fq "makevn doctor" "${TMP}/.makevn/logs/docker-up.log"
grep -Fq "makevn doctor" "${MAKEVN_BACKEND_DETAIL_OUT}"

# Required-service checks preserve Compose daemon errors for the reporter.
cat > "${TMP}/compose" <<'COMPOSE'
#!/usr/bin/env bash
if [[ "${FAKE_COMPOSE_MODE:-}" == stopped ]]; then
  printf 'failed to connect to the docker API at unix:///Users/test/.colima/work/docker.sock\n' >&2
  exit 1
fi
# An available daemon with no container must not get a runtime hint.
printf 'benign compose warning\n' >&2
COMPOSE
chmod +x "${TMP}/compose"
for mode in stopped missing; do
  FAKE_COMPOSE_MODE="${mode}" COMPOSE_ARGS='-f ignored' SERVICES='db cache' DOCKER_COMPOSE="${TMP}/compose" \
    bash "${ROOT_DIR}/libexec/makevn/docker/ps.sh" > "${TMP}/required.log"
  grep -q 'missing' "${TMP}/required.log"
  : > "${MAKEVN_BACKEND_DETAIL_OUT}"
  makevn_report_docker_runtime_failure docker-ps-required "${TMP}/required.log" 2>/dev/null
  if [[ "${mode}" == stopped ]]; then
    grep -Fq '.colima/work/docker.sock' "${TMP}/required.log"
    grep -Fq 'makevn doctor' "${MAKEVN_BACKEND_DETAIL_OUT}"
  else
    [[ ! -s "${MAKEVN_BACKEND_DETAIL_OUT}" ]]
    ! grep -Fq 'Hint:' "${TMP}/required.log"
    ! grep -Fq 'benign compose warning' "${TMP}/required.log"
  fi
done
