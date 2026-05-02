#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${ROOT_DIR}/bin/makevn"
BACKEND="${ROOT_DIR}/libexec/makevn/backend.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/makevn-smoke.XXXXXX")"

cleanup() {
  rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "expected file to exist: $1"
}

assert_dir_exists() {
  [[ -d "$1" ]] || fail "expected directory to exist: $1"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_contains() {
  local path="$1"
  local text="$2"
  grep -Fq "${text}" "${path}" || fail "expected ${path} to contain: ${text}"
}

assert_not_contains() {
  local path="$1"
  local text="$2"
  if grep -Fq "${text}" "${path}"; then
    fail "expected ${path} not to contain: ${text}"
  fi
}

assert_matches() {
  local path="$1"
  local pattern="$2"
  grep -Eq "${pattern}" "${path}" || fail "expected ${path} to match regex: ${pattern}"
}

run_makevn_pty_interrupt() {
  local mode="$1"
  local repo="$2"
  local output_file="$3"

  python3 - "${mode}" "${repo}" "${output_file}" <<'PY'
import os
import pty
import select
import signal
import sys
import time

mode, repo, output_file = sys.argv[1:4]
cmd = ['/Users/antonio.saco/Projects/antonillos/makevn/bin/makevn', '--repo', repo, 'build']

pid, fd = pty.fork()
if pid == 0:
    os.execv(cmd[0], cmd)

output = bytearray()
status = None
sent_first_esc = False
sent_second_esc = False
start = time.time()

while True:
    readable, _, _ = select.select([fd], [], [], 0.1)
    if fd in readable:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        output.extend(chunk)

    elapsed = time.time() - start
    if mode == 'double-esc':
        if elapsed > 0.5 and not sent_first_esc:
            os.write(fd, b'\x1b')
            sent_first_esc = True
        if elapsed > 1.0 and not sent_second_esc:
            os.write(fd, b'\x1b')
            sent_second_esc = True
    elif mode == 'ctrl-c' and elapsed > 1.0:
        os.kill(pid, signal.SIGINT)
        mode = 'ctrl-c-sent'

    try:
        waited = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        break
    if waited != (0, 0):
        status = waited[1]
        break

if status is None:
    status = os.waitpid(pid, 0)[1]

while True:
    try:
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        output.extend(chunk)
    except OSError:
        break

with open(output_file, 'wb') as fh:
    fh.write(output)

raise SystemExit(os.waitstatus_to_exitcode(status))
PY
}

detect_java_home() {
  local java_home=""
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    printf '%s\n' "${JAVA_HOME}"
    return 0
  fi
  if command -v java >/dev/null 2>&1; then
    java_home="$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/^[[:space:]]*java.home = / { print $2; exit }')"
    if [[ -n "${java_home}" && -x "${java_home}/bin/java" ]]; then
      printf '%s\n' "${java_home}"
      return 0
    fi
  fi
  fail "could not detect a usable JAVA_HOME for smoke tests"
}

test_doctor_unsupported() {
  local repo="${TMP_ROOT}/unsupported"
  mkdir -p "${repo}"
  local output
  output="$(${CLI} --repo "${repo}" doctor)"
  [[ "${output}" == *"Recommended mode: unsupported"* ]] || fail "doctor should report unsupported on non-Maven repo"
}

test_backend_doctor_json() {
  local repo="${TMP_ROOT}/doctor-json"
  local output_file="${TMP_ROOT}/doctor-json.out"

  mkdir -p "${repo}"
  bash "${BACKEND}" doctor --repo "${repo}" --format json > "${output_file}"

  python3 - "${output_file}" "${repo}" <<'PY'
import json
import sys

output_file, repo = sys.argv[1:3]
with open(output_file, 'r', encoding='utf-8') as fh:
    data = json.load(fh)

assert data['version'] == 1, data
assert data['command'] == 'doctor', data
assert data['repository_analysis']['repo_root'] == repo, data
assert data['repository_analysis']['recommended_mode'] == 'unsupported', data
assert data['suggested_next_step']['note'] == 'no automatic recommendation: Maven repository signals were not detected', data
PY
}

test_standalone_mode() {
  local repo="${TMP_ROOT}/standalone"
  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  ${CLI} --repo "${repo}" init --mode standalone >/dev/null
  assert_dir_exists "${repo}/.makevn"
  assert_file_exists "${repo}/.makevn/config"
  assert_file_exists "${repo}/.makevn/profile.env"
  assert_dir_exists "${repo}/.makevn/logs"
  assert_not_exists "${repo}/Makefile"
  ${CLI} --repo "${repo}" uninstall >/dev/null
  assert_not_exists "${repo}/.makevn"
}

test_make_include_mode() {
  local repo="${TMP_ROOT}/make-include"
  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  cat > "${repo}/Makefile" <<'EOF'
all:
	@printf 'existing makefile\n'
EOF
  ${CLI} --repo "${repo}" init --mode make-include --write-make-include >/dev/null
  assert_file_exists "${repo}/.makevn/makevn.mk"
  assert_contains "${repo}/Makefile" "# makevn:begin"
  assert_contains "${repo}/Makefile" "include .makevn/makevn.mk"
  rtk make -C "${repo}" vn-doctor >/dev/null
  ${CLI} --repo "${repo}" uninstall >/dev/null
  assert_not_exists "${repo}/.makevn"
  assert_file_exists "${repo}/Makefile"
  assert_not_contains "${repo}/Makefile" "# makevn:begin"
}

test_make_bootstrap_mode() {
  local repo="${TMP_ROOT}/make-bootstrap"
  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  ${CLI} --repo "${repo}" init --mode make-bootstrap >/dev/null
  assert_file_exists "${repo}/Makefile"
  assert_file_exists "${repo}/.makevn/makevn.mk"
  assert_contains "${repo}/Makefile" "Generated by makevn"
  rtk make -C "${repo}" vn-doctor >/dev/null
  ${CLI} --repo "${repo}" uninstall >/dev/null
  assert_not_exists "${repo}/Makefile"
  assert_not_exists "${repo}/.makevn"
}

test_installer() {
  local prefix="${TMP_ROOT}/install-prefix"
  PREFIX="${prefix}" "${ROOT_DIR}/install.sh" >/dev/null
  assert_file_exists "${prefix}/bin/makevn"
  assert_file_exists "${prefix}/libexec/makevn/jdk/manager.sh"
  assert_file_exists "${prefix}/libexec/makevn/docker/ps.sh"
  assert_file_exists "${prefix}/libexec/makevn/coverage/changes.sh"
  assert_file_exists "${prefix}/libexec/makevn/compat/verify_changes.sh"
  assert_file_exists "${prefix}/share/makevn/makevn.mk"
  assert_file_exists "${prefix}/share/makevn/skills/makevn/SKILL.md"
  "${prefix}/bin/makevn" --help >/dev/null
}

test_auto_mode() {
  local repo="${TMP_ROOT}/auto-mode"
  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  cat > "${repo}/Makefile" <<'EOF'
all:
	@true
EOF
  ${CLI} --repo "${repo}" init --mode auto >/dev/null
  assert_file_exists "${repo}/.makevn/makevn.mk"
  assert_not_contains "${repo}/Makefile" "# makevn:begin"
  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_profile_refresh() {
  local repo="${TMP_ROOT}/profile-refresh"
  mkdir -p "${repo}/.github/workflows"
  printf '<project/>\n' > "${repo}/pom.xml"

  ${CLI} --repo "${repo}" init --mode make-bootstrap >/dev/null

  cat > "${repo}/.makevn/makevn.mk" <<'EOF'
MAKEVN_BIN ?= makevn
vn-test:
	@"$(MAKEVN_BIN)" test
EOF

  cat > "${repo}/.github/workflows/build.yml" <<'EOF'
jobs:
  build:
    steps:
      - run: mvn -B package -Dmaven.build.cache.enabled=false -DskipTests
EOF

  ${CLI} --repo "${repo}" profile refresh >/dev/null
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_BUILD_PROP_FLAGS=-Dmaven.build.cache.enabled=false'
  assert_contains "${repo}/.makevn/makevn.mk" 'define makevn_run'

  cat > "${repo}/.github/workflows/build.yml" <<'EOF'
jobs:
  build:
    steps:
      - run: mvn -B clean package -Dmaven.build.cache.enabled=true -DskipTests
EOF

  ${CLI} --repo "${repo}" profile refresh >/dev/null
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_BUILD_PRE_GOALS=clean'
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_BUILD_PROP_FLAGS=-Dmaven.build.cache.enabled=true'

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_interactive_pid_output() {
  local repo="${TMP_ROOT}/interactive-pid"
  local java_home
  local output_file="${TMP_ROOT}/interactive-pid.out"

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  java_home="$(detect_java_home)"

  ${CLI} --repo "${repo}" init --mode standalone >/dev/null

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 1
printf 'interactive-build\n'
EOF
  chmod +x "${repo}/mvnw"

  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  script -q /dev/null bash -lc "\"${CLI}\" --repo \"${repo}\" build" > "${output_file}" 2>&1

  assert_matches "${output_file}" 'pid:.*[0-9]+'
  assert_matches "${repo}/.makevn/logs/build.log" '^pid: [0-9]+$'
  [[ "$(tr -d '\r' < "${output_file}")" != *"running build"* ]] || fail "expected interactive output not to include redundant spinner status text"
  [[ "$(tr -d '\r' < "${output_file}")" != *"■"* ]] || fail "expected shell backend output not to include kitt-style spinner glyphs"
  [[ "$(tr -d '\r' < "${output_file}")" != *"0s"* ]] || fail "expected interactive output not to include inline seconds"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_interactive_ctrl_c_interrupt() {
  local repo="${TMP_ROOT}/interactive-int"
  local java_home
  local output_file="${TMP_ROOT}/interactive-int.out"
  local rc=0

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  java_home="$(detect_java_home)"

  ${CLI} --repo "${repo}" init --mode standalone >/dev/null

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 5
EOF
  chmod +x "${repo}/mvnw"

  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  set +e
  run_makevn_pty_interrupt ctrl-c "${repo}" "${output_file}"
  rc=$?
  set -e

  [[ ${rc} -eq 130 ]] || fail "expected ctrl+c interrupt to return 130, got ${rc}"
  [[ ! -n "$(pgrep -f "${repo}/mvnw" || true)" ]] || fail "expected ctrl+c interrupted mvnw process to be stopped"
  [[ ! -n "$(pgrep -f "/libexec/makevn/cli.sh --repo ${repo} build" || true)" ]] || fail "expected ctrl+c interrupted makevn process to be stopped"
  [[ "$(tr -d '\r' < "${output_file}")" == *"interrupted after "* ]] || fail "expected ctrl+c output to include interrupted message"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_make_failure_output() {
  local repo="${TMP_ROOT}/make-failure"
  local java_home
  local output

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  java_home="$(detect_java_home)"

  ${CLI} --repo "${repo}" init --mode make-bootstrap >/dev/null

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'failing-test\n' >&2
exit 7
EOF
  chmod +x "${repo}/mvnw"

  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  output="$(rtk make -f .makevn/makevn.mk -C "${repo}" vn-test 2>&1 || true)"

  [[ "${output}" == *"fail exit 7 after "* ]] || fail "expected make failure output to include friendly makevn error"
  [[ "${output}" == *"gmake: ***"* ]] || fail "expected make failure output to still include gmake failure"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_tail_degrades_without_tty() {
  local repo="${TMP_ROOT}/tail-without-tty"
  local install_prefix="${TMP_ROOT}/tail-without-tty-install"
  local tail_cli="${install_prefix}/bin/makevn"
  local java_home

  [[ -x "${ROOT_DIR}/target/release/makevn" ]] || return 0

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  java_home="$(detect_java_home)"

  PREFIX="${install_prefix}" "${ROOT_DIR}/install.sh" --rust >/dev/null
  "${tail_cli}" --repo "${repo}" init --mode make-bootstrap >/dev/null
  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
printf 'JAVA_HOME=%s\n' "${JAVA_HOME:-}" >> .mvnw.log
EOF
  chmod +x "${repo}/mvnw"
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  "${tail_cli}" --repo "${repo}" --tail validate >/dev/null

  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml validate$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"

  "${tail_cli}" --repo "${repo}" uninstall >/dev/null
}

test_command_routing() {
  local repo="${TMP_ROOT}/command-routing"
  local java_home
  local make_output
  mkdir -p "${repo}"
  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"
  mkdir -p "${repo}/.github/workflows"
  mkdir -p "${repo}/module-a/src/test/java/com/example"
  java_home="$(detect_java_home)"
  ${CLI} --repo "${repo}" init --mode make-bootstrap >/dev/null
  cat > "${repo}/.github/workflows/build.yml" <<'EOF'
jobs:
  build:
    steps:
      - run: ./mvnw -B clean package -Dmaven.build.cache.enabled=false -Damiga-javaformat.skip=true -DskipTests
EOF
  cat > "${repo}/.github/workflows/test.yml" <<'EOF'
jobs:
  test:
    steps:
      - run: mvn -B test -Dsurefire.failIfNoSpecifiedTests=false
EOF
  cat > "${repo}/.github/workflows/verify.yml" <<'EOF'
jobs:
  verify:
    steps:
      - run: mvn -nsu clean verify -DskipITs -DfailIfNoTests=false
EOF
  ${CLI} --repo "${repo}" profile refresh >/dev/null
  cat > "${repo}/module-a/src/test/java/com/example/UserRepositoryTest.java" <<'EOF'
package com.example;

class UserRepositoryTest {}
EOF
  cat > "${repo}/module-a/src/test/java/com/example/OrderRepositoryTest.java" <<'EOF'
package com.example;

class OrderRepositoryTest {}
EOF
  cat > "${repo}/module-a/src/test/java/com/example/UserFlowIT.java" <<'EOF'
package com.example;

class UserFlowIT {}
EOF
  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
printf 'JAVA_HOME=%s\n' "${JAVA_HOME:-}" >> .mvnw.log
for arg in "$@"; do
  if [[ "${arg}" == "failsafe:integration-test" ]]; then
    mkdir -p module-a/target/failsafe-reports
    cat > module-a/target/failsafe-reports/failsafe-summary.xml <<'XML'
<failsafe-summary result="null">
  <completed>1</completed>
  <errors>0</errors>
  <failures>0</failures>
</failsafe-summary>
XML
  fi
done
EOF
  chmod +x "${repo}/mvnw"
  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker-compose %s\n' "$*" >> .docker-compose.log
if [[ "$1" == "-f" ]]; then
  printf 'fake-service-id\n'
fi
EOF
  chmod +x "${repo}/fake-bin/docker-compose"
  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> .docker.log
if [[ "$1" == "compose" && "${2:-}" == "version" ]]; then
  exit 0
fi
if [[ "$1" == "inspect" && "${2:-}" == "-f" ]]; then
  case "$3" in
    '{{.State.Status}}')
      printf 'running\n'
      ;;
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
      printf 'healthy\n'
      ;;
    '{{.Name}}')
      printf '/fake-db\n'
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "${repo}/fake-bin/docker"
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD="printf run-ok > run.out"
EOF
  local build_output
  local package_output
  build_output="$(PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" build)"
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" compile-tests >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" validate >/dev/null
  package_output="$(PATH="${repo}/fake-bin:${PATH}" rtk make -f .makevn/makevn.mk -C "${repo}" vn-package)"
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" clean >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" test >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" test --name UserRepositoryTest >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" test --name UserRepositoryTest,OrderRepositoryTest >/dev/null
  mkdir -p "${repo}/module-a/target/test-classes"
  make_output="$(PATH="${repo}/fake-bin:${PATH}" rtk make -f .makevn/makevn.mk -C "${repo}" vn-test NAME=UserRepositoryTest FAST=true)"
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" test --name UserFlowIT >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" exec -- bash -lc 'printf "%s" "$JAVA_HOME" > exec-java-home.txt' >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" run >/dev/null
  [[ "${build_output}" == *"[ok] "* ]] || fail "expected build output to include success summary"
  [[ "${package_output}" == *"[ok] "* ]] || fail "expected vn-package output to include success summary"
  [[ "${make_output}" == *"[ok] "* ]] || fail "expected vn-test fast output to include success summary"
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_MAVEN_CLI_FLAGS=-B\ -nsu'
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_BUILD_PRE_GOALS=clean'
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_BUILD_PROP_FLAGS=-Dmaven.build.cache.enabled=false\ -Damiga-javaformat.skip=true'
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_TEST_PROP_FLAGS=-Dsurefire.failIfNoSpecifiedTests=false'
  assert_not_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_VERIFY_PRE_GOALS=clean'
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_VERIFY_PROP_FLAGS=-DfailIfNoTests=false'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml clean package -Dmaven\.build\.cache\.enabled=false -Damiga-javaformat\.skip=true -DskipTests$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml test-compile$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml validate$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml clean package -Dmaven\.build\.cache\.enabled=false -Damiga-javaformat\.skip=true$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml clean$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml test -Dsurefire\.failIfNoSpecifiedTests=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml -pl module-a -am test -Dsurefire\.failIfNoSpecifiedTests=false -Damiga-javaformat\.skip=true -Dtest=com\.example\.UserRepositoryTest -Dfailsafe\.failIfNoSpecifiedTests=false -Dmaven\.build\.cache\.enabled=true -Dsurefire\.testFailureIgnore=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml -pl module-a -am test -Dsurefire\.failIfNoSpecifiedTests=false -Damiga-javaformat\.skip=true -Dtest=com\.example\.OrderRepositoryTest -Dfailsafe\.failIfNoSpecifiedTests=false -Dmaven\.build\.cache\.enabled=true -Dsurefire\.testFailureIgnore=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml -pl module-a -am surefire:test -Dsurefire\.failIfNoSpecifiedTests=false -Damiga-javaformat\.skip=true -Dtest=com\.example\.UserRepositoryTest -Dfailsafe\.failIfNoSpecifiedTests=false -Dmaven\.build\.cache\.enabled=true -Dsurefire\.testFailureIgnore=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml -pl module-a -am test-compile failsafe:integration-test -Dsurefire\.failIfNoSpecifiedTests=false -Damiga-javaformat\.skip=true -Dit\.test=com\.example\.UserFlowIT -Dfailsafe\.failIfNoSpecifiedTests=false -Dmaven\.build\.cache\.enabled=true$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml verify -DfailIfNoTests=false$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"
  assert_contains "${repo}/exec-java-home.txt" "${java_home}"
  assert_contains "${repo}/run.out" "run-ok"
  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_docker_commands() {
  local repo="${TMP_ROOT}/docker-commands"
  local output

  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"

  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker-compose %s\n' "$*" >> .docker-compose.log
EOF
  chmod +x "${repo}/fake-bin/docker-compose"

  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> .docker.log
if [[ "$1" == "compose" && "${2:-}" == "version" ]]; then
  exit 0
fi
if [[ "$1" == "volume" && "${2:-}" == "prune" && "${3:-}" == "-f" ]]; then
  exit 0
fi
if [[ "$1" == "ps" && "${2:-}" == "-aq" ]]; then
  printf 'abc123def456\n'
  exit 0
fi
if [[ "$1" == "inspect" && "${2:-}" == "-f" ]]; then
  case "$3" in
    '{{.Name}}')
      printf '/fake-db\n'
      ;;
    '{{.State.Status}}')
      printf 'running\n'
      ;;
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
      printf 'healthy\n'
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "${repo}/fake-bin/docker"

  cat > "${repo}/fake-bin/makevn-wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="${repo}/fake-bin:\$PATH"
exec "${CLI}" "\$@"
EOF
  chmod +x "${repo}/fake-bin/makevn-wrapper"

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" init --mode make-bootstrap >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" docker-up >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" docker-down >/dev/null
  output="$(rtk make -f .makevn/makevn.mk -C "${repo}" MAKEVN_BIN="${repo}/fake-bin/makevn-wrapper" vn-docker-ps)"

  assert_matches "${repo}/.docker-compose.log" '^docker-compose -f .*/code/boot/src/test/resources/compose/docker-compose\.yml -f .*/code/boot/src/test/resources/compose/docker-compose\.override\.yml down -v --remove-orphans$'
  assert_matches "${repo}/.docker-compose.log" '^docker-compose -f .*/code/boot/src/test/resources/compose/docker-compose\.yml -f .*/code/boot/src/test/resources/compose/docker-compose\.override\.yml up --detach$'
  assert_contains "${repo}/.docker.log" "docker volume prune -f"
  [[ "${output}" == *"fake-db"* ]] || fail "expected docker ps output to include fake container name"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_verify_split_commands() {
  local repo="${TMP_ROOT}/verify-split"
  local java_home
  local output
  local pr_output

  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"
  java_home="$(detect_java_home)"

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
printf 'JAVA_HOME=%s\n' "${JAVA_HOME:-}" >> .mvnw.log
EOF
  chmod +x "${repo}/mvnw"

  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker-compose %s\n' "$*" >> .docker-compose.log
if [[ "$1" == "-f" ]]; then
  printf 'fake-service-id\n'
fi
EOF
  chmod +x "${repo}/fake-bin/docker-compose"

  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> .docker.log
if [[ "$1" == "compose" && "${2:-}" == "version" ]]; then
  exit 0
fi
if [[ "$1" == "inspect" && "${2:-}" == "-f" ]]; then
  case "$3" in
    '{{.State.Status}}')
      printf 'running\n'
      ;;
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
      printf 'healthy\n'
      ;;
    '{{.Name}}')
      printf '/fake-db\n'
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "${repo}/fake-bin/docker"

  cat > "${repo}/fake-bin/makevn-wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="${repo}/fake-bin:\$PATH"
exec "${CLI}" "\$@"
EOF
  chmod +x "${repo}/fake-bin/makevn-wrapper"

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" init --mode make-bootstrap >/dev/null
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify-ut >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify-ut-coverage >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify-it >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify-it-coverage >/dev/null
  output="$(rtk make -f .makevn/makevn.mk -C "${repo}" MAKEVN_BIN="${repo}/fake-bin/makevn-wrapper" vn-verify-ut)"
  pr_output="$(rtk make -f .makevn/makevn.mk -C "${repo}" MAKEVN_BIN="${repo}/fake-bin/makevn-wrapper" vn-pr-verify)"
  rtk make -f .makevn/makevn.mk -C "${repo}" MAKEVN_BIN="${repo}/fake-bin/makevn-wrapper" vn-docker-ps-required >/dev/null

  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml verify -Djacoco\.skip=false -Damiga\.jacoco -DskipITs -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml verify -Djacoco\.skip=false -Damiga\.jacoco -DskipUTs -Dskip\.unit\.tests=true -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false -Dmaven\.build\.cache\.enabled=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml clean verify -Djacoco\.skip=false -Damiga\.jacoco -DskipITs -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false -Damiga-javaformat\.skip=true -Dmaven\.build\.cache\.enabled=false$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"
  assert_matches "${repo}/.docker-compose.log" '^docker-compose -f .*/code/boot/src/test/resources/compose/docker-compose\.yml -f .*/code/boot/src/test/resources/compose/docker-compose\.override\.yml ps -q db$'
  [[ "${output}" == *"[ok] "* ]] || fail "expected vn-verify-ut output to include success summary"
  [[ "${pr_output}" == *"[ok] "* ]] || fail "expected vn-pr-verify output to include success summary"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_verify_it_requires_running_services() {
  local repo="${TMP_ROOT}/verify-it-missing-services"
  local java_home
  local output

  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"
  java_home="$(detect_java_home)"

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
printf 'JAVA_HOME=%s\n' "${JAVA_HOME:-}" >> .mvnw.log
EOF
  chmod +x "${repo}/mvnw"

  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker-compose %s\n' "$*" >> .docker-compose.log
exit 0
EOF
  chmod +x "${repo}/fake-bin/docker-compose"

  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> .docker.log
if [[ "$1" == "compose" && "${2:-}" == "version" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "${repo}/fake-bin/docker"

  ${CLI} --repo "${repo}" init --mode make-bootstrap >/dev/null
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  output="$(PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify-it 2>&1 || true)"

  [[ "${output}" == *"db"* ]] || fail "expected verify-it failure output to mention missing db service"
  [[ "${output}" == *"Required Docker services are not running or healthy"* ]] || fail "expected verify-it to fail on missing required services"
  [[ ! -f "${repo}/.mvnw.log" ]] || fail "expected verify-it not to invoke Maven when services are missing"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_verify_it_uses_verify_lifecycle_when_verify_workflow_skips_it() {
  local repo="${TMP_ROOT}/verify-it-lifecycle"
  local java_home

  mkdir -p "${repo}/.github/workflows"
  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"
  java_home="$(detect_java_home)"

  cat > "${repo}/.github/workflows/verify.yml" <<'EOF'
jobs:
  verify:
    steps:
      - run: mvn -B -nsu clean verify -DskipITs -DfailIfNoTests=false -Damiga-javaformat.skip=true
EOF

  ${CLI} --repo "${repo}" init --mode make-bootstrap >/dev/null
  ${CLI} --repo "${repo}" profile refresh >/dev/null

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
printf 'JAVA_HOME=%s\n' "${JAVA_HOME:-}" >> .mvnw.log
EOF
  chmod +x "${repo}/mvnw"
  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker-compose %s\n' "$*" >> .docker-compose.log
if [[ "$1" == "-f" ]]; then
  printf 'fake-service-id\n'
fi
EOF
  chmod +x "${repo}/fake-bin/docker-compose"
  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> .docker.log
if [[ "$1" == "compose" && "${2:-}" == "version" ]]; then
  exit 0
fi
if [[ "$1" == "inspect" && "${2:-}" == "-f" ]]; then
  case "$3" in
    '{{.State.Status}}')
      printf 'running\n'
      ;;
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
      printf 'healthy\n'
      ;;
    '{{.Name}}')
      printf '/fake-db\n'
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "${repo}/fake-bin/docker"

  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify-it >/dev/null

  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml verify -DfailIfNoTests=false -Damiga-javaformat\.skip=true -Djacoco\.skip=false -Damiga\.jacoco -DskipUTs -Dskip\.unit\.tests=true -Dmaven\.test\.failure\.ignore=false -Dmaven\.build\.cache\.enabled=false$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_verify_it_prefers_integration_workflow_when_available() {
  local repo="${TMP_ROOT}/verify-it-workflow"
  local java_home

  mkdir -p "${repo}/.github/workflows"
  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project>\n  <dependencies>\n    <dependency>\n      <groupId>org.testcontainers</groupId>\n      <artifactId>testcontainers</artifactId>\n    </dependency>\n  </dependencies>\n</project>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"
  java_home="$(detect_java_home)"

  cat > "${repo}/.github/workflows/unit.yml" <<'EOF'
jobs:
  unit:
    steps:
      - run: mvn -B clean verify -DskipITs -DfailIfNoTests=false
EOF

  cat > "${repo}/.github/workflows/integration.yml" <<'EOF'
jobs:
  integration:
    steps:
      - run: mvn -B -nsu install -Djacoco.skip=false -Damiga.jacoco -DskipUTs -Dskip.unit.tests=true -DfailIfNoTests=false -Dmaven.test.failure.ignore=false
EOF

  ${CLI} --repo "${repo}" init --mode make-bootstrap >/dev/null
  ${CLI} --repo "${repo}" profile refresh >/dev/null

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
printf 'JAVA_HOME=%s\n' "${JAVA_HOME:-}" >> .mvnw.log
printf 'LOCAL_CONTAINERS=%s\n' "${LOCAL_CONTAINERS:-}" >> .mvnw.log
EOF
  chmod +x "${repo}/mvnw"
  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker-compose %s\n' "$*" >> .docker-compose.log
if [[ "$1" == "-f" ]]; then
  printf 'fake-service-id\n'
fi
EOF
  chmod +x "${repo}/fake-bin/docker-compose"
  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> .docker.log
if [[ "$1" == "compose" && "${2:-}" == "version" ]]; then
  exit 0
fi
if [[ "$1" == "inspect" && "${2:-}" == "-f" ]]; then
  case "$3" in
    '{{.State.Status}}')
      printf 'running\n'
      ;;
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
      printf 'healthy\n'
      ;;
    '{{.Name}}')
      printf '/fake-db\n'
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "${repo}/fake-bin/docker"

  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify-it >/dev/null

  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml -B -nsu verify -Djacoco\.skip=false -Damiga\.jacoco -DskipUTs -Dskip\.unit\.tests=true -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false -Dmaven\.build\.cache\.enabled=false$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"
  assert_contains "${repo}/.mvnw.log" "LOCAL_CONTAINERS=TRUE"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_verify_changes_command() {
  local repo="${TMP_ROOT}/verify-changes"
  local java_home
  local output

  mkdir -p "${repo}/module-a/src/test/java/com/example"
  printf '<project/>\n' > "${repo}/pom.xml"
  java_home="$(detect_java_home)"

  cat > "${repo}/module-a/src/test/java/com/example/ChangedTest.java" <<'EOF'
package com.example;

class ChangedTest {}
EOF

  rtk git init "${repo}" >/dev/null
  rtk git -C "${repo}" add .
  rtk git -C "${repo}" -c user.name='Smoke Test' -c user.email='smoke@example.com' commit -m 'init' >/dev/null
  printf '// local change\n' >> "${repo}/module-a/src/test/java/com/example/ChangedTest.java"

  ${CLI} --repo "${repo}" init --mode make-bootstrap >/dev/null
  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
printf 'JAVA_HOME=%s\n' "${JAVA_HOME:-}" >> .mvnw.log
EOF
  chmod +x "${repo}/mvnw"
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  output="$(${CLI} --repo "${repo}" verify-changes)"

  [[ "${output}" == *"[ok] "* ]] || fail "expected verify-changes output to include success summary"
  assert_matches "${repo}/.mvnw.log" '^ARGS=-nsu -f .*/pom\.xml verify -Damiga-javaformat\.skip=true -DskipUTs=false -Dtest=com\.example\.ChangedTest -Dit\.test=com\.example\.ChangedTest -Dfailsafe\.failIfNoSpecifiedTests=false -Dsurefire\.failIfNoSpecifiedTests=false -Dawaitility\.defaultPollInterval=200ms -Dawaitility\.defaultTimeout=2m -Djacoco\.skip=false -Damiga\.jacoco -Dmaven\.build\.cache\.enabled=false$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_coverage_changes_command() {
  local repo="${TMP_ROOT}/coverage-changes"
  local output

  mkdir -p "${repo}/module-a/src/main/java/com/example"
  mkdir -p "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/com.example"
  printf '<project/>\n' > "${repo}/pom.xml"

  cat > "${repo}/module-a/src/main/java/com/example/Changed.java" <<'EOF'
package com.example;

class Changed {
  int value() {
    return 0;
  }
}
EOF

  cat > "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/com.example/Changed.java.html" <<'EOF'
<html><body>
<span class="fc" id="L5">    return 1;</span>
</body></html>
EOF

  cat > "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/jacoco.csv" <<'EOF'
GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED
makevn,com.example,Changed,0,10,0,0,0,1,0,1,0,1
EOF
  printf '<html></html>\n' > "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/index.html"

  rtk git init "${repo}" >/dev/null
  rtk git -C "${repo}" add .
  rtk git -C "${repo}" -c user.name='Smoke Test' -c user.email='smoke@example.com' commit -m 'init' >/dev/null
  perl -0pi -e 's/return 0;/return 1;/' "${repo}/module-a/src/main/java/com/example/Changed.java"

  output="$(${CLI} --repo "${repo}" coverage-changes --threshold 90)"

  [[ "${output}" == *"Incremental Coverage: ✓ 100%"* ]] \
    || fail "expected coverage-changes output to pass incremental coverage"
  [[ "${output}" == *"Quality gate conditions met"* ]] \
    || fail "expected coverage-changes output to include overall quality gate"
}

test_verify_rejects_skip_flags() {
  local repo="${TMP_ROOT}/verify-rejects-skip-flags"
  local output=""

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"

  output="$(${CLI} --repo "${repo}" verify -- -DskipITs 2>&1 || true)"

  [[ "${output}" == *"verify does not accept UT/IT skip flags; use verify-ut or verify-it instead"* ]] \
    || fail "expected verify to reject IT/UT skip flags"
}

test_sequential_commands() {
  local repo="${TMP_ROOT}/sequential-commands"
  local install_prefix="${TMP_ROOT}/sequential-install"
  local seq_cli="${install_prefix}/bin/makevn"
  local java_home

  [[ -x "${ROOT_DIR}/target/release/makevn" ]] || return 0
  PREFIX="${install_prefix}" "${ROOT_DIR}/install.sh" --rust >/dev/null

  mkdir -p "${repo}"
  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"
  java_home="$(detect_java_home)"

  "${seq_cli}" --repo "${repo}" init --mode standalone >/dev/null

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
printf 'JAVA_HOME=%s\n' "${JAVA_HOME:-}" >> .mvnw.log
EOF
  chmod +x "${repo}/mvnw"
  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker-compose %s\n' "$*" >> .docker-compose.log
if [[ "$1" == "-f" ]]; then
  printf 'fake-service-id\n'
fi
EOF
  chmod +x "${repo}/fake-bin/docker-compose"
  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> .docker.log
if [[ "$1" == "compose" && "${2:-}" == "version" ]]; then
  exit 0
fi
if [[ "$1" == "inspect" && "${2:-}" == "-f" ]]; then
  case "$3" in
    '{{.State.Status}}')
      printf 'running\n'
      ;;
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
      printf 'healthy\n'
      ;;
    '{{.Name}}')
      printf '/fake-db\n'
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "${repo}/fake-bin/docker"

  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  PATH="${repo}/fake-bin:${PATH}" "${seq_cli}" --repo "${repo}" clean verify-it >/dev/null

  assert_file_exists "${repo}/.makevn/logs/clean.log"
  assert_file_exists "${repo}/.makevn/logs/verify-it.log"
  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml clean$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml verify -Djacoco\.skip=false -Damiga\.jacoco -DskipUTs -Dskip\.unit\.tests=true -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false -Dmaven\.build\.cache\.enabled=false$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"

  "${seq_cli}" --repo "${repo}" uninstall >/dev/null
}

test_command_typo_rejected_before_backend() {
  local repo="${TMP_ROOT}/command-typo"
  local install_prefix="${TMP_ROOT}/command-typo-install"
  local typo_cli="${install_prefix}/bin/makevn"
  local output=""

  [[ -x "${ROOT_DIR}/target/release/makevn" ]] || return 0
  PREFIX="${install_prefix}" "${ROOT_DIR}/install.sh" --rust >/dev/null

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"

  output="$("${typo_cli}" --repo "${repo}" --tail compile verity-ut 2>&1 || true)"

  [[ "${output}" == *"Unknown command: verity-ut"* ]] || fail "expected command typo to be rejected by frontend"
  [[ "${output}" == *"Did you mean 'verify-ut'?"* ]] || fail "expected command typo to suggest verify-ut"
  [[ "${output}" != *"check the log"* ]] || fail "expected command typo not to look like a backend run failure"
  assert_not_exists "${repo}/.makevn/logs/compile.log"
}

test_command_failure_summary_omits_duplicate_elapsed() {
  local repo="${TMP_ROOT}/command-failure-summary"
  local install_prefix="${TMP_ROOT}/command-failure-summary-install"
  local fail_cli="${install_prefix}/bin/makevn"
  local java_home
  local output=""

  [[ -x "${ROOT_DIR}/target/release/makevn" ]] || return 0
  PREFIX="${install_prefix}" "${ROOT_DIR}/install.sh" --rust >/dev/null

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  java_home="$(detect_java_home)"

  "${fail_cli}" --repo "${repo}" init --mode standalone >/dev/null
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 7
EOF
  chmod +x "${repo}/mvnw"

  output="$("${fail_cli}" --repo "${repo}" compile 2>&1 || true)"

  [[ "${output}" == *"Worked for "* ]] || fail "expected dashboard elapsed to be present"
  [[ "${output}" == *"[fail] exit 7 | check the log"* ]] || fail "expected compact failure summary without duplicate elapsed"
  if [[ "${output}" =~ \[fail\]\ exit\ 7\ \|\ [0-9]+s\ \|\ check\ the\ log ]]; then
    fail "expected failure summary not to repeat elapsed after dashboard"
  fi
}

main() {
  test_doctor_unsupported
  test_backend_doctor_json
  test_standalone_mode
  test_make_include_mode
  test_make_bootstrap_mode
  test_installer
  test_auto_mode
  test_profile_refresh
  test_interactive_pid_output
  test_interactive_ctrl_c_interrupt
  test_make_failure_output
  test_tail_degrades_without_tty
  test_command_routing
  test_docker_commands
  test_verify_split_commands
  test_verify_it_requires_running_services
  test_verify_it_uses_verify_lifecycle_when_verify_workflow_skips_it
  test_verify_it_prefers_integration_workflow_when_available
  test_verify_changes_command
  test_coverage_changes_command
  test_verify_rejects_skip_flags
  test_sequential_commands
  test_command_typo_rejected_before_backend
  test_command_failure_summary_omits_duplicate_elapsed
  printf 'Smoke tests passed\n'
}

main "$@"
