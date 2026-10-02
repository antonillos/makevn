#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common.sh"
source "${ROOT_DIR}/libexec/makevn/commands/karate.sh"
source "${ROOT_DIR}/libexec/makevn/commands/run.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/makevn-readiness.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT
assert_equal() { [[ "$1" == "$2" ]] || { printf 'Expected <%s>, got <%s>\n' "$2" "$1" >&2; exit 1; }; }
assert_rejected() {
  local expected="$1"
  shift
  if ("$@") >"${TMP_ROOT}/error" 2>&1; then
    printf 'Expected rejection: %s\n' "$*" >&2; exit 1
  fi
  [[ -z "${expected}" ]] || grep -Fq -- "${expected}" "${TMP_ROOT}/error"
}
test_timeout_validation() (
  makevn_validate_app_health_timeout 1
  makevn_validate_app_health_timeout 60
  makevn_validate_app_health_timeout 2147483647
  local invalid
  for invalid in 0 -1 abc 1.5 01 2147483648 999999999999999999999 ''; do
    assert_rejected 'positive integer' makevn_validate_app_health_timeout "${invalid}"
  done
)
test_url_precedence() (
  mkdir -p "${TMP_ROOT}/repo/.makevn"
  printf 'MAKEVN_APP_HEALTH_URL="http://config/health"\n' >"${TMP_ROOT}/repo/.makevn/config"
  printf 'MAKEVN_PROFILE_APP_HEALTH_URL="http://profile/health"\n' >"${TMP_ROOT}/repo/.makevn/profile.env"
  makevn_detect_app_health_url() { printf 'http://detected/health\n'; }
  assert_equal "$(makevn_app_health_url "${TMP_ROOT}/repo" /fake/code)" http://config/health
  : >"${TMP_ROOT}/repo/.makevn/config"
  assert_equal "$(makevn_app_health_url "${TMP_ROOT}/repo" /fake/code)" http://profile/health
  : >"${TMP_ROOT}/repo/.makevn/profile.env"
  assert_equal "$(makevn_app_health_url "${TMP_ROOT}/repo" /fake/code)" http://detected/health
)
test_probe_statuses_and_limits() (
  curl() { printf '%s\n' "$*" >"${TMP_ROOT}/curl-args"; printf '%s' "${STATUS}"; return "${CURL_RC:-0}"; }
  local STATUS
  for STATUS in 200 204 299; do makevn_probe_app_health http://localhost/health 10; done
  grep -Fq -- '--connect-timeout 2 --max-time 5' "${TMP_ROOT}/curl-args"
  for STATUS in 000 199 301 404 503 '' 200garbage; do
    assert_rejected '' makevn_probe_app_health http://localhost/health 10
  done
  STATUS=200 CURL_RC=7
  assert_rejected '' makevn_probe_app_health http://localhost/health 10
  CURL_RC=0
  makevn_probe_app_health http://localhost/health 1
  grep -Fq -- '--connect-timeout 1 --max-time 1' "${TMP_ROOT}/curl-args"
)
test_wait_retries_and_deadline() (
  local calls=0
  sleep() { SECONDS=$((SECONDS + 1)); }
  makevn_probe_app_health() { calls=$((calls + 1)); (( calls >= 3 )); }
  SECONDS=0
  makevn_wait_app_health http://localhost/health 5 >"${TMP_ROOT}/wait"
  assert_equal "${calls}" 3
  grep -Fq 'HTTP 2xx verified' "${TMP_ROOT}/wait"
  makevn_probe_app_health() { SECONDS=$((SECONDS + $2)); return 1; }
  SECONDS=0
  if makevn_wait_app_health http://localhost/health 5 >"${TMP_ROOT}/wait" 2>&1; then exit 1; fi
  assert_equal "${SECONDS}" 5
  grep -Fq 'MAKEVN_APP_HEALTH_TIMEOUT=120' "${TMP_ROOT}/wait"
  grep -Fq 'check the health URL and HTTP response' "${TMP_ROOT}/wait"
  ! grep -Fq 'Error:' "${TMP_ROOT}/wait"
  grep -Fq 'did not respond with HTTP 2xx within 5s' "${TMP_ROOT}/wait"
)
test_wait_exited_process() (
  makevn_app_process_exited() { return 0; }
  makevn_probe_app_health() { echo unexpected >"${TMP_ROOT}/unexpected"; }
  printf 'startup failure detail\n' >"${TMP_ROOT}/app.log"
  if makevn_wait_app_health http://localhost/health 5 123 "${TMP_ROOT}/app.log" >"${TMP_ROOT}/wait" 2>&1; then exit 1; fi
  assert_equal "${MAKEVN_APP_PROCESS_EXITED}" yes
  [[ ! -f "${TMP_ROOT}/unexpected" ]]
  grep -Fq 'startup failure detail' "${TMP_ROOT}/wait"
)
test_karate_preflight_and_lifecycle() (
  local url='' karate_test_rc=0
  makevn_detect_maven_base_path() { echo /fake/code; }
  makevn_detect_app_runnable() { return 0; }
  makevn_load_config() { :; }
  makevn_app_health_url() { printf '%s' "${url}"; }
  cmd_karate_docker_up() { echo docker >>"${TMP_ROOT}/steps"; }
  cmd_docker_ps_required() { :; }
  cmd_package() { echo package >>"${TMP_ROOT}/steps"; }
  cmd_run_app_bg() {
    assert_equal "$2" http://resolved/health
    assert_equal "$3" 7
    echo ready >>"${TMP_ROOT}/steps"
  }
  cmd_karate_test() { echo tests >>"${TMP_ROOT}/steps"; return "${karate_test_rc}"; }
  cmd_stop_app() { echo stop >>"${TMP_ROOT}/steps"; }
  assert_rejected MAKEVN_APP_HEALTH_URL cmd_karate_all /fake/repo
  [[ ! -f "${TMP_ROOT}/steps" ]]
  url=http://resolved/health
  MAKEVN_APP_HEALTH_TIMEOUT=invalid
  assert_rejected 'positive integer' cmd_karate_all /fake/repo
  [[ ! -f "${TMP_ROOT}/steps" ]]
  MAKEVN_APP_HEALTH_TIMEOUT=7
  cmd_karate_all /fake/repo
  assert_equal "$(tr '\n' ' ' <"${TMP_ROOT}/steps")" 'docker package ready tests stop '
  : >"${TMP_ROOT}/steps"
  karate_test_rc=42
  local rc=0
  if cmd_karate_all /fake/repo; then rc=0; else rc=$?; fi
  assert_equal "${rc}" 42
  assert_equal "$(tail -n 1 "${TMP_ROOT}/steps")" stop
)
test_timeout_validation
test_url_precedence
test_probe_statuses_and_limits
test_wait_retries_and_deadline
test_wait_exited_process
test_karate_preflight_and_lifecycle
python3 "${ROOT_DIR}/test/smoke/karate_readiness_http_fixture.py" "${ROOT_DIR}"
printf 'Karate readiness tests passed\n'

# The managed dashboard replaces waiting status, preserving unrelated details.
(
  export MAKEVN_BACKEND_DETAIL_OUT="${TMP_ROOT}/compact-details"
  printf 'profiles: standalone,local (config)\n' > "${MAKEVN_BACKEND_DETAIL_OUT}"
  makevn_probe_app_health() { return 0; }
  makevn_wait_app_health http://localhost/health 120
  grep -Fq 'profiles: standalone,local (config)' "${MAKEVN_BACKEND_DETAIL_OUT}"
  grep -Fq 'health URL: http://localhost/health' "${MAKEVN_BACKEND_DETAIL_OUT}"
  grep -Fq 'readiness: HTTP 2xx verified | timeout: 120s' "${MAKEVN_BACKEND_DETAIL_OUT}"
  [[ $(grep -c '^readiness:' "${MAKEVN_BACKEND_DETAIL_OUT}") == 1 ]]
  ! grep -q 'waiting for' "${MAKEVN_BACKEND_DETAIL_OUT}"
)
