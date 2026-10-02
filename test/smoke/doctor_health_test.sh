#!/usr/bin/env bash
# Sourced by run.sh; can also run independently for focused verification.

doctor_health_pty() {
  python3 "${ROOT_DIR}/test/smoke/doctor_health_prompt_test.py" "${CLI}" "$@"
}

doctor_health_fixture() {
  local repo="$1"
  mkdir -p "${repo}/src/main/java/com/example"
  printf '<project><modelVersion>4.0.0</modelVersion><groupId>com.example</groupId><artifactId>app</artifactId><version>1</version></project>\n' >"${repo}/pom.xml"
  printf 'public class Application { public static void main(String[] args) {} }\n' >"${repo}/src/main/java/com/example/Application.java"
  "${CLI}" --repo "${repo}" init >/dev/null
}

test_doctor_does_not_invent_health_check() {
  local repo="${TMP_ROOT}/doctor-no-health"
  local output

  mkdir -p "${repo}/src/main/resources"
  cat > "${repo}/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>sample</artifactId>
  <version>1.0.0</version>
</project>
EOF
  cat > "${repo}/src/main/resources/application.yml" <<'EOF'
server:
  port: 18080
EOF

  output="$(${CLI} --repo "${repo}" doctor)"

  [[ "${output}" == *"Detected app health URL: not detected"* ]] || fail "doctor should not invent an app health URL"
}

test_doctor_detects_actuator_health_check() {
  local repo="${TMP_ROOT}/doctor-actuator-health"
  local output

  mkdir -p "${repo}/src/main/resources"
  cat > "${repo}/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>sample</artifactId>
  <version>1.0.0</version>
  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
  </dependencies>
</project>
EOF
  cat > "${repo}/src/main/resources/application.yml" <<'EOF'
server:
  port: 18080
EOF

  output="$(${CLI} --repo "${repo}" doctor)"

  [[ "${output}" == *"Detected app health URL: http://localhost:18080/actuator/health"* ]] || fail "doctor should detect Actuator health URL"
}

test_doctor_local_containers_prompt_also_prompts_health() {
  local repo="${TMP_ROOT}/doctor-local-containers-health-pty"
  local output_file="${TMP_ROOT}/doctor-local-containers-health-pty.out"

  mkdir -p "${repo}/.github/workflows" "${repo}/src/main/resources"
  cat > "${repo}/pom.xml" <<'EOF'
<project>
  <dependencies>
    <dependency>
      <groupId>org.testcontainers</groupId>
      <artifactId>testcontainers</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
  </dependencies>
</project>
EOF
  cat > "${repo}/src/main/resources/application.yml" <<'EOF'
server:
  port: 18080
EOF
  cat > "${repo}/.github/workflows/integration.yml" <<'EOF'
jobs:
  integration:
    steps:
      - run: mvn -B verify -DskipUTs
EOF

  ${CLI} --repo "${repo}" init >/dev/null

  mkdir -p "${repo}/src/main/java/com/example"
  printf 'public class Application { public static void main(String[] args) {} }\n' >"${repo}/src/main/java/com/example/Application.java"
  doctor_health_pty "${repo}" "${output_file}" '[ ["Enter number [1-2]:", "1"], ["Health URL [", ""] ]'

  assert_contains "${output_file}" "Saved to .makevn/config (MAKEVN_LOCAL_CONTAINERS)."
  assert_contains "${output_file}" "LOCAL_CONTAINERS default: TRUE"
  assert_contains "${output_file}" "Health URL ["
  assert_contains "${output_file}" "Saved to .makevn/config (MAKEVN_APP_HEALTH_URL)."
  assert_contains "${repo}/.makevn/config" "http://localhost:18080/actuator/health"
}


test_doctor_missing_health_prompt() {
  local repo="${TMP_ROOT}/doctor-missing-health"
  local output="${TMP_ROOT}/doctor-missing-health.out"
  doctor_health_fixture "${repo}"
  doctor_health_pty "${repo}" "${output}" '[ ["Health URL [", "http://localhost:18080/custom/health"] ]'
  assert_contains "${output}" 'No application health URL detected'
  assert_contains "${output}" 'Suggested URL (not verified): http://localhost:8080/health'
  assert_contains "${output}" 'Saved to .makevn/config (MAKEVN_APP_HEALTH_URL).'
  assert_contains "${repo}/.makevn/config" 'http://localhost:18080/custom/health'
  doctor_health_pty "${repo}" "${output}" '[]'
  assert_not_contains "${output}" 'Health URL ['
  assert_contains "${output}" '(from config)'
}

test_doctor_health_skip_and_noninteractive() {
  local repo="${TMP_ROOT}/doctor-health-skip"
  local output="${TMP_ROOT}/doctor-health-skip.out"
  doctor_health_fixture "${repo}"
  doctor_health_pty "${repo}" "${output}" '[ ["Health URL [", "skip"] ]'
  assert_not_contains "${repo}/.makevn/config" 'MAKEVN_APP_HEALTH_URL='
  assert_contains "${output}" 'karate-all requires this URL'
  "${CLI}" --repo "${repo}" doctor >"${output}" 2>&1
  assert_not_contains "${output}" 'Health URL ['
  assert_contains "${output}" 'Set MAKEVN_APP_HEALTH_URL'
  bash "${ROOT_DIR}/libexec/makevn/backend.sh" doctor --repo "${repo}" --format json >"${output}"
  python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); assert "MAKEVN_APP_HEALTH_URL" in data["suggested_next_step"]["note"]' "${output}"
  "${CLI}" --repo "${repo}" profile refresh >"${output}" 2>&1
  assert_not_contains "${output}" 'Health URL ['
  assert_not_contains "${repo}/.makevn/config" 'MAKEVN_APP_HEALTH_URL='
}

test_doctor_health_invalid_and_explicit_url() {
  local repo="${TMP_ROOT}/doctor-health-invalid"
  local output="${TMP_ROOT}/doctor-health-invalid.out"
  doctor_health_fixture "${repo}"
  doctor_health_pty "${repo}" "${output}" '[ ["Health URL [", "file:///health"], ["Health URL [", "https://localhost:18080/ready"] ]'
  assert_contains "${output}" 'Invalid health URL'
  assert_contains "${repo}/.makevn/config" 'https://localhost:18080/ready'
}

test_doctor_health_confirms_suggested_default() {
  local repo="${TMP_ROOT}/doctor-health-default"
  local output="${TMP_ROOT}/doctor-health-default.out"
  doctor_health_fixture "${repo}"
  mkdir -p "${repo}/src/main/resources"
  printf 'server.port=18082\nserver.servlet.context-path=/sample\n' >"${repo}/src/main/resources/application.properties"
  doctor_health_pty "${repo}" "${output}" '[ ["Health URL [", ""] ]'
  assert_contains "${output}" 'Suggested URL (not verified): http://localhost:18082/sample/health'
  assert_contains "${repo}/.makevn/config" 'http://localhost:18082/sample/health'
}

test_doctor_health_readline_fallback() {
  local repo="${TMP_ROOT}/doctor-health-readline"
  local output="${TMP_ROOT}/doctor-health-readline.out"
  doctor_health_fixture "${repo}"
  mkdir -p "${repo}/fake-bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${repo}/fake-bin/zsh"
  chmod +x "${repo}/fake-bin/zsh"
  PATH="${repo}/fake-bin:${PATH}" doctor_health_pty "${repo}" "${output}" '[ ["Health URL [", "skip"] ]'
  assert_not_contains "${repo}/.makevn/config" 'MAKEVN_APP_HEALTH_URL='
  PATH="${repo}/fake-bin:${PATH}" doctor_health_pty "${repo}" "${output}" '[ ["Health URL [", "http://localhost:18090/ready"] ]'
  assert_contains "${repo}/.makevn/config" 'http://localhost:18090/ready'
}

test_doctor_health_config_roundtrip() (
  source "${ROOT_DIR}/libexec/makevn/common.sh"
  local repo="${TMP_ROOT}/doctor-health-config-roundtrip"
  local url='http://localhost/health?literal=$(false)&quote="value"&slash=\'
  doctor_health_fixture "${repo}"
  makevn_update_config_app_health_url "${repo}" "${url}"
  makevn_update_config_app_health_url "${repo}" "${url}"
  makevn_load_config "${repo}"
  [[ "${MAKEVN_APP_HEALTH_URL}" == "${url}" ]] || fail 'health URL must survive safe config persistence'
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  CLI="${ROOT_DIR}/bin/makevn"
  source "${ROOT_DIR}/libexec/makevn/common.sh"
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/makevn-doctor-health.XXXXXX")"
  trap 'rm -rf "${TMP_ROOT}"' EXIT
  fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
  assert_contains() { grep -Fq -- "$2" "$1" || fail "missing $2 in $1"; }
  assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "unexpected $2 in $1"; }
  test_doctor_does_not_invent_health_check
  test_doctor_detects_actuator_health_check
  test_doctor_missing_health_prompt
  test_doctor_health_skip_and_noninteractive
  test_doctor_health_invalid_and_explicit_url
  test_doctor_health_confirms_suggested_default
  test_doctor_health_readline_fallback
  test_doctor_health_config_roundtrip
  test_doctor_local_containers_prompt_also_prompts_health
  printf 'Doctor health prompt tests passed\n'
fi
