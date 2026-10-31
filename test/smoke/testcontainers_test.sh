#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/module"
printf '<project><dependencies><dependency><groupId>org.testcontainers</groupId></dependency></dependencies></project>\n' > "${TMP}/module/pom.xml"
for command in test verify verify-ut verify-ut-coverage verify-it verify-it-coverage verify-changes; do
  makevn_testcontainers_command "${TMP}" "${command}"
done
for command in compile test-compile package clean validate; do
  ! makevn_testcontainers_command "${TMP}" "${command}"
done
rm "${TMP}/module/pom.xml"
! makevn_testcontainers_command "${TMP}" verify

# An engine failure must remain a failure, not become an empty container list.
docker() { printf 'Cannot connect to the Docker daemon\n' >&2; return 42; }
export -f docker
export DOCKER_COMPOSE=unused
set +e
bash "${ROOT_DIR}/libexec/makevn/docker/ps.sh" > "${TMP}/out" 2>&1
status=$?
set -e
[[ ${status} -eq 42 ]]
grep -q 'Cannot connect' "${TMP}/out"
docker() { return 0; }
bash "${ROOT_DIR}/libexec/makevn/docker/ps.sh" > "${TMP}/out"
grep -q NAME "${TMP}/out"

# Exercise the managed Maven execution boundary, including failure logs.
printf '<project><groupId>org.testcontainers</groupId></project>\n' > "${TMP}/pom.xml"
mkdir "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in
  context) printf 'unix:///tmp/testcontainers.sock\n' ;;
  info)
    [[ "${DOCKER_HOST}" == unix:///tmp/testcontainers.sock ]]
    if [[ "${FAKE_ENGINE:-}" == stopped ]]; then
      printf 'Cannot connect to the Docker daemon\n' >&2
      exit 42
    fi
    printf '28\n'
    ;;
  *) exit 99 ;;
esac
DOCKER
chmod +x "${TMP}/fake-bin/docker"
export PATH="${TMP}/fake-bin:${PATH}"
unset DOCKER_HOST
export DOCKER_CONTEXT=local
makevn_test_process_preflight() { return 0; }
makevn_effective_java_home() { printf '/usr\n'; }
makevn_check_maven_command() { return 0; }
MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${TMP}" code "${TMP}" verify verify verify \
  /bin/sh -c 'printf "child host: %s\n" "$DOCKER_HOST"; test -z "${DOCKER_CONTEXT:-}"' > "${TMP}/out"
grep -q 'child host: unix:///tmp/testcontainers.sock' "${TMP}/.makevn/logs/verify.log"
if FAKE_ENGINE=stopped MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context \
    "${TMP}" code "${TMP}" verify verify verify touch "${TMP}/tests-started" > "${TMP}/out" 2>&1; then
  exit 1
fi
[[ ! -e "${TMP}/tests-started" ]]
grep -q 'Testcontainers Docker prerequisite failed' "${TMP}/.makevn/logs/verify.log"
grep -q 'Tests were not started' "${TMP}/out"
printf 'Testcontainers command routing and Docker error tests passed\n'
