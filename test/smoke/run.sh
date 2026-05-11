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

make_test_jar_with_manifest() {
  local jar_file="$1"
  local main_class="$2"
  local start_class="${3:-}"
  local tmp_dir="${TMP_ROOT}/jar.$RANDOM.$$"

  mkdir -p "${tmp_dir}/META-INF"
  {
    printf 'Manifest-Version: 1.0\r\n'
    if [[ -n "${main_class}" ]]; then
      printf 'Main-Class: %s\r\n' "${main_class}"
    fi
    if [[ -n "${start_class}" ]]; then
      printf 'Start-Class: %s\r\n' "${start_class}"
    fi
    printf '\r\n'
  } > "${tmp_dir}/META-INF/MANIFEST.MF"
  (cd "${tmp_dir}" && zip -qr "${jar_file}" META-INF)
  rm -rf "${tmp_dir}"
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

run_makevn_pty_command() {
  local cli="$1"
  local repo="$2"
  local command="$3"
  local output_file="$4"

  python3 - "${cli}" "${repo}" "${command}" "${output_file}" <<'PY'
import os
import pty
import select
import sys

cli, repo, command, output_file = sys.argv[1:5]
cmd = [cli, '--repo', repo, command]

pid, fd = pty.fork()
if pid == 0:
    os.execv(cmd[0], cmd)

output = bytearray()
status = None

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
  [[ "${output}" == *"Repository support status: unsupported"* ]] || fail "doctor should report unsupported on non-Maven repo"
  [[ "${output}" == *"Current makevn status: not initialized"* ]] || fail "doctor should report not initialized on non-Maven repo"
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
assert data['repository_analysis']['repository_support_status'] == 'unsupported', data
assert data['repository_analysis']['current_makevn_status'] == 'not initialized', data
assert data['repository_analysis']['make_integration_status'] == 'not installed', data
assert data['suggested_next_step']['note'] == 'no automatic recommendation: Maven repository signals were not detected', data
PY
}

test_doctor_resolves_java_version_from_pom() {
  local repo="${TMP_ROOT}/doctor-pom-java-version"
  local fake_java_home="${repo}/fake-java-home"
  local output

  mkdir -p "${repo}" "${fake_java_home}/bin"
  cat > "${repo}/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>sample</artifactId>
  <version>1.0.0</version>
  <properties>
    <maven.compiler.source>21</maven.compiler.source>
    <maven.compiler.target>21</maven.compiler.target>
  </properties>
</project>
EOF
  cat > "${fake_java_home}/bin/java" <<'EOF'
#!/usr/bin/env bash
printf 'openjdk version "21.0.1" 2024-01-01\n' >&2
EOF
  chmod +x "${fake_java_home}/bin/java"

  output="$(JAVA_HOME="${fake_java_home}" ${CLI} --repo "${repo}" doctor)"

  [[ "${output}" == *"Code .tool-versions: unresolved"* ]] || fail "doctor should report missing .tool-versions"
  [[ "${output}" == *"Code Java version: 21"* ]] || fail "doctor should detect Java version from pom.xml"
  [[ "${output}" == *"Application runnable: no"* ]] || fail "doctor should report non-runnable library project"
  [[ "${output}" == *"Resolved code JAVA_HOME: ${fake_java_home}"* ]] || fail "doctor should resolve code JAVA_HOME from pom.xml Java version"

  ${CLI} --repo "${repo}" init >/dev/null
  assert_contains "${repo}/.makevn/profile.env" "MAKEVN_PROFILE_CODE_JAVA_VERSION=21"
}

test_doctor_resolves_java_version_from_pom_property_reference() {
  local repo="${TMP_ROOT}/doctor-pom-java-property-reference"
  local fake_java_home="${repo}/fake-java-home"
  local output

  mkdir -p "${repo}" "${fake_java_home}/bin"
  cat > "${repo}/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>sample</artifactId>
  <version>1.0.0</version>
  <properties>
    <project.java.version>1.8</project.java.version>
    <maven.compiler.release>${project.java.version}</maven.compiler.release>
  </properties>
</project>
EOF
  cat > "${fake_java_home}/bin/java" <<'EOF'
#!/usr/bin/env bash
printf 'openjdk version "1.8.0_402" 2024-01-01\n' >&2
EOF
  chmod +x "${fake_java_home}/bin/java"

  output="$(JAVA_HOME="${fake_java_home}" ${CLI} --repo "${repo}" doctor)"

  [[ "${output}" == *"Code Java version: 8"* ]] || fail "doctor should resolve Java version property references from pom.xml"
  [[ "${output}" == *"Resolved code JAVA_HOME: ${fake_java_home}"* ]] || fail "doctor should resolve code JAVA_HOME from referenced pom.xml Java version"
}

test_doctor_resolves_java_version_from_compiler_plugin_source() {
  local repo="${TMP_ROOT}/doctor-pom-compiler-plugin-source"
  local fake_java_home="${repo}/fake-java-home"
  local output

  mkdir -p "${repo}" "${fake_java_home}/bin"
  cat > "${repo}/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>sample</artifactId>
  <version>1.0.0</version>
  <build>
    <plugins>
      <plugin>
        <artifactId>maven-compiler-plugin</artifactId>
        <configuration>
          <source>1.8</source>
          <target>1.8</target>
        </configuration>
      </plugin>
    </plugins>
  </build>
</project>
EOF
  cat > "${fake_java_home}/bin/java" <<'EOF'
#!/usr/bin/env bash
printf 'openjdk version "1.8.0_402" 2024-01-01\n' >&2
EOF
  chmod +x "${fake_java_home}/bin/java"

  output="$(JAVA_HOME="${fake_java_home}" ${CLI} --repo "${repo}" doctor)"

  [[ "${output}" == *"Code Java version: 8"* ]] || fail "doctor should resolve Java version from maven-compiler-plugin source/target"
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

test_doctor_shows_progress_in_tty() {
  local repo="${TMP_ROOT}/doctor-progress"
  local output_file="${TMP_ROOT}/doctor-progress.out"

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  mkdir -p "${repo}/.makevn"
  cat > "${repo}/.makevn/config" <<'EOF'
MAKEVN_MIN_COVERAGE_THRESHOLD="70"
MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD="70"
EOF

  script -q /dev/null bash -lc "\"${CLI}\" --repo \"${repo}\" doctor" > "${output_file}" 2>&1

  assert_contains "${output_file}" "Inspecting repository layout"
  assert_contains "${output_file}" "Scanning workflow and Maven signals"
  assert_contains "${output_file}" "Resolving Java homes"
}

test_doctor_reports_compatible_newer_java_homes() {
  local repo="${TMP_ROOT}/doctor-compatible-java"
  local fake_home_root="${TMP_ROOT}/fake-home"
  local java17_home="${fake_home_root}/.sdkman/candidates/java/17.0.9-tem"
  local java21_home="${fake_home_root}/.sdkman/candidates/java/21.0.3-tem"
  local output

  mkdir -p "${repo}" "${java17_home}/bin" "${java21_home}/bin"
  cat > "${repo}/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>sample</artifactId>
  <version>1.0.0</version>
  <properties>
    <maven.compiler.source>6</maven.compiler.source>
    <maven.compiler.target>6</maven.compiler.target>
  </properties>
</project>
EOF
  cat > "${java17_home}/bin/java" <<'EOF'
#!/usr/bin/env bash
printf 'openjdk version "17.0.9" 2024-01-01\n' >&2
EOF
  cat > "${java21_home}/bin/java" <<'EOF'
#!/usr/bin/env bash
printf 'openjdk version "21.0.3" 2024-01-01\n' >&2
EOF
  chmod +x "${java17_home}/bin/java" "${java21_home}/bin/java"

  output="$(HOME="${fake_home_root}" ${CLI} --repo "${repo}" doctor)"

  [[ "${output}" == *"Code Java version: 6"* ]] || fail "doctor should detect the requested Java version from pom.xml"
  [[ "${output}" == *"Resolved code JAVA_HOME: ${java17_home}"* ]] || fail "doctor should resolve to the lowest compatible newer JDK when no exact match is installed"
}

test_exec_uses_compatible_newer_java_home() {
  local repo="${TMP_ROOT}/exec-compatible-java"
  local fake_home_root="${TMP_ROOT}/fake-exec-home"
  local java17_home="${fake_home_root}/.sdkman/candidates/java/17.0.9-tem"

  mkdir -p "${repo}" "${java17_home}/bin"
  cat > "${repo}/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>sample</artifactId>
  <version>1.0.0</version>
  <properties>
    <maven.compiler.source>6</maven.compiler.source>
    <maven.compiler.target>6</maven.compiler.target>
  </properties>
</project>
EOF
  cat > "${java17_home}/bin/java" <<'EOF'
#!/usr/bin/env bash
printf 'openjdk version "17.0.9" 2024-01-01\n' >&2
EOF
  chmod +x "${java17_home}/bin/java"

  HOME="${fake_home_root}" ${CLI} --repo "${repo}" exec -- bash -lc 'printf "%s\n" "${JAVA_HOME}"' > "${repo}/exec.out"

  assert_contains "${repo}/exec.out" "${java17_home}"
}

test_run_app_bg_disabled_without_executable_app() {
  local repo="${TMP_ROOT}/run-app-bg-disabled-library"
  local java_home="${repo}/fake-java-home"
  local output=""

  mkdir -p "${repo}/code/boot/target" "${repo}/fake-java-home/bin"
  cat > "${repo}/code/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>library</artifactId>
  <version>1.0.0</version>
</project>
EOF
  printf 'fake jar\n' > "${repo}/code/boot/target/library.jar"
  cat > "${repo}/fake-java-home/bin/java" <<'EOF'
#!/usr/bin/env bash
printf 'openjdk version "21.0.1" 2024-01-01\n' >&2
EOF
  chmod +x "${repo}/fake-java-home/bin/java"

  ${CLI} --repo "${repo}" init >/dev/null
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME="${java_home}"
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  output="$(${CLI} --repo "${repo}" run-app-bg 2>&1 || true)"

  [[ "${output}" == *"run-app is disabled: no executable application was detected"* ]] || fail "run-app-bg should be disabled for library projects"
}

test_standalone_mode() {
  local repo="${TMP_ROOT}/standalone"
  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  ${CLI} --repo "${repo}" init >/dev/null
  assert_dir_exists "${repo}/.makevn"
  assert_file_exists "${repo}/.makevn/config"
  assert_contains "${repo}/.makevn/config" 'MAKEVN_FORMAT_CHECK_GOAL=""'
  assert_contains "${repo}/.makevn/config" 'MAKEVN_FORMAT_APPLY_GOAL=""'
  assert_contains "${repo}/.makevn/config" 'MAKEVN_CHECKSTYLE_GOAL=""'
  assert_file_exists "${repo}/.makevn/profile.env"
  assert_dir_exists "${repo}/.makevn/logs"
  assert_not_exists "${repo}/Makefile"
  ${CLI} --repo "${repo}" uninstall >/dev/null
  assert_not_exists "${repo}/.makevn"
}

test_init_force_preserves_config() {
  local repo="${TMP_ROOT}/init-force-preserves-config"

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"

  ${CLI} --repo "${repo}" init >/dev/null
  cat > "${repo}/.makevn/config" <<'EOF'
# makevn local configuration
MAKEVN_JAVA_HOME=""
MAKEVN_CODE_JAVA_HOME="/custom/java"
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
MAKEVN_FORMAT_CHECK_GOAL=""
MAKEVN_FORMAT_APPLY_GOAL=""
MAKEVN_CHECKSTYLE_GOAL=""
MAKEVN_COVERAGE_PROP_FLAGS="-Djacoco.skip=false"
MAKEVN_MIN_COVERAGE_THRESHOLD="70"
MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD="70"
MAKEVN_COMPOSE_FILE=""
MAKEVN_E2E_COMPOSE_FILE=""
EOF

  ${CLI} --repo "${repo}" init --force >/dev/null

  assert_contains "${repo}/.makevn/config" 'MAKEVN_CODE_JAVA_HOME="/custom/java"'
  assert_contains "${repo}/.makevn/config" 'MAKEVN_MIN_COVERAGE_THRESHOLD="70"'
  assert_contains "${repo}/.makevn/config" 'MAKEVN_MIN_COVERAGE_CHANGES_THRESHOLD="70"'
}

test_format_requires_configured_formatter() {
  local repo="${TMP_ROOT}/format-unconfigured"
  local output_file="${TMP_ROOT}/format-unconfigured.out"

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  ${CLI} --repo "${repo}" init >/dev/null

  if ${CLI} --repo "${repo}" format --apply >"${output_file}" 2>&1; then
    fail "format should fail when no formatter plugin or explicit goal is configured"
  fi

  assert_contains "${output_file}" "No formatting plugin configured for this Maven project"
}

test_checkstyle_requires_configured_plugin() {
  local repo="${TMP_ROOT}/checkstyle-unconfigured"
  local output_file="${TMP_ROOT}/checkstyle-unconfigured.out"

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  ${CLI} --repo "${repo}" init >/dev/null

  if ${CLI} --repo "${repo}" checkstyle >"${output_file}" 2>&1; then
    fail "checkstyle should fail when no Checkstyle plugin or explicit goal is configured"
  fi

  assert_contains "${output_file}" "No Checkstyle plugin configured for this Maven project"
}

test_make_install_existing_makefile() {
  local repo="${TMP_ROOT}/make-install-existing-makefile"
  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  cat > "${repo}/Makefile" <<'EOF'
all:
	@printf 'existing makefile\n'
EOF
  ${CLI} --repo "${repo}" init >/dev/null
  ${CLI} --repo "${repo}" make install >/dev/null
  assert_file_exists "${repo}/.makevn/makevn.mk"
  assert_contains "${repo}/Makefile" "# makevn:begin"
  assert_contains "${repo}/Makefile" "include .makevn/makevn.mk"
  rtk make -C "${repo}" vn-doctor >/dev/null
  ${CLI} --repo "${repo}" make uninstall >/dev/null
  assert_dir_exists "${repo}/.makevn"
  assert_file_exists "${repo}/Makefile"
  assert_not_contains "${repo}/Makefile" "# makevn:begin"
  ${CLI} --repo "${repo}" uninstall >/dev/null
  assert_not_exists "${repo}/.makevn"
  assert_file_exists "${repo}/Makefile"
}

test_make_install_without_makefile() {
  local repo="${TMP_ROOT}/make-install-without-makefile"
  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  ${CLI} --repo "${repo}" init >/dev/null
  ${CLI} --repo "${repo}" make install >/dev/null
  assert_file_exists "${repo}/Makefile"
  assert_file_exists "${repo}/.makevn/makevn.mk"
  assert_contains "${repo}/Makefile" "Generated by makevn"
  rtk make -C "${repo}" vn-doctor >/dev/null
  ${CLI} --repo "${repo}" make uninstall >/dev/null
  assert_not_exists "${repo}/Makefile"
  assert_dir_exists "${repo}/.makevn"
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

test_init_does_not_touch_existing_makefile() {
  local repo="${TMP_ROOT}/init-existing-makefile"
  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  cat > "${repo}/Makefile" <<'EOF'
all:
	@true
EOF
  ${CLI} --repo "${repo}" init >/dev/null
  assert_not_exists "${repo}/.makevn/makevn.mk"
  assert_not_contains "${repo}/Makefile" "# makevn:begin"
  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_profile_refresh() {
  local repo="${TMP_ROOT}/profile-refresh"
  mkdir -p "${repo}/.github/workflows"
  printf '<project/>\n' > "${repo}/pom.xml"

  ${CLI} --repo "${repo}" init >/dev/null

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
  assert_contains "${repo}/.makevn/profile.env" "MAKEVN_PROFILE_BUILD_PROP_FLAGS=''"
  assert_contains "${repo}/.makevn/makevn.mk" 'define makevn_run'

  cat > "${repo}/.github/workflows/build.yml" <<'EOF'
jobs:
  build:
    steps:
      - run: mvn -B clean package -Dmaven.build.cache.enabled=true -DskipTests
EOF

  ${CLI} --repo "${repo}" profile refresh >/dev/null
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_BUILD_PRE_GOALS=clean'
  assert_contains "${repo}/.makevn/profile.env" "MAKEVN_PROFILE_BUILD_PROP_FLAGS=''"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_profile_refresh_bans_ci_only_verify_flags() {
  local repo="${TMP_ROOT}/profile-refresh-bans"
  mkdir -p "${repo}/.github/workflows"
  printf '<project/>\n' > "${repo}/pom.xml"

  ${CLI} --repo "${repo}" init >/dev/null

  cat > "${repo}/.github/workflows/verify.yml" <<'EOF'
jobs:
  verify:
    steps:
      - run: mvn -B verify -Dmaven.build.cache.enabled=true -DskipITs -DskipUTs -Dsonar.token=fake -DoutputName=report -Dexec.args=foo -DskipEnforceSnapshots -Djacoco.skip=false -Dcoverage.profile=true -DfailIfNoTests=false -Dmaven.test.failure.ignore=false
EOF

  ${CLI} --repo "${repo}" profile refresh >/dev/null
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_VERIFY_CLI_FLAGS=-B'
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_VERIFY_PROP_FLAGS=-DskipEnforceSnapshots -Djacoco.skip=false -Dcoverage.profile=true -DfailIfNoTests=false -Dmaven.test.failure.ignore=false'
  assert_not_contains "${repo}/.makevn/profile.env" '-Dmaven.build.cache.enabled=true'
  assert_not_contains "${repo}/.makevn/profile.env" '-DskipITs'
  assert_not_contains "${repo}/.makevn/profile.env" '-DskipUTs'
  assert_not_contains "${repo}/.makevn/profile.env" '-Dsonar.token=fake'
  assert_not_contains "${repo}/.makevn/profile.env" '-DoutputName=report'
  assert_not_contains "${repo}/.makevn/profile.env" '-Dexec.args=foo'

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_interactive_pid_output() {
  local repo="${TMP_ROOT}/interactive-pid"
  local java_home
  local output_file="${TMP_ROOT}/interactive-pid.out"

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  java_home="$(detect_java_home)"

  ${CLI} --repo "${repo}" init >/dev/null
  ${CLI} --repo "${repo}" make install >/dev/null

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

  ${CLI} --repo "${repo}" init >/dev/null

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

  ${CLI} --repo "${repo}" init >/dev/null

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

  [[ "${output}" == *"make: ***"* || "${output}" == *"gmake: ***"* ]] || fail "expected make failure output to still include make failure"

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
  "${tail_cli}" --repo "${repo}" init >/dev/null
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

test_non_tty_run_is_compact_and_keeps_full_log_in_file() {
  local repo="${TMP_ROOT}/compact-non-tty"
  local java_home
  local output=""

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  java_home="$(detect_java_home)"

  ${CLI} --repo "${repo}" init >/dev/null
  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'line-01\n'
printf 'line-02\n'
printf 'line-03\n'
printf 'line-04\n'
printf 'line-05\n'
printf 'line-06\n'
printf 'line-07\n'
printf 'line-08\n'
printf 'line-09\n'
printf 'line-10\n'
printf 'line-11\n'
printf 'line-12\n'
printf 'line-13\n'
printf 'line-14\n'
printf 'line-15\n'
printf 'line-16\n'
printf 'line-17\n'
printf 'line-18\n'
printf 'line-19\n'
printf 'line-20\n'
printf 'line-21\n'
printf 'line-22\n'
printf 'line-23\n'
printf 'line-24\n'
printf 'line-25\n'
printf 'line-26\n'
printf 'line-27\n'
printf 'line-28\n'
printf 'line-29\n'
printf 'line-30\n'
printf 'line-31\n'
printf 'line-32\n'
printf 'line-33\n'
printf 'line-34\n'
printf 'line-35\n'
printf 'line-36\n'
printf 'line-37\n'
printf 'line-38\n'
printf 'line-39\n'
printf 'line-40\n'
printf 'line-41\n'
printf 'line-42\n'
printf 'line-43\n'
printf 'line-44\n'
printf 'line-45\n'
printf 'line-46\n'
printf 'line-47\n'
printf 'line-48\n'
printf 'line-49\n'
printf 'line-50\n'
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

  output="$(${CLI} --repo "${repo}" compile 2>&1)"

  [[ "${output}" == *"[ok] "* ]] || fail "expected compact output to include success summary"
  [[ "${output}" != *"line-50"* ]] || fail "expected compact output not to stream full Maven log"
  assert_contains "${repo}/.makevn/logs/compile.log" "line-50"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_command_routing() {
  local repo="${TMP_ROOT}/command-routing"
  local java_home
  local make_output
  mkdir -p "${repo}"
  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  cat > "${repo}/pom.xml" <<'EOF'
<project>
  <build>
    <plugins>
      <plugin>
        <groupId>com.example.format</groupId>
        <artifactId>custom-javaformat-maven-plugin</artifactId>
        <executions>
          <execution>
            <goals>
              <goal>validate</goal>
              <goal>apply</goal>
            </goals>
          </execution>
        </executions>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-checkstyle-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
EOF
  printf 'services:\n  db:\n    image: postgres:16\n  admin:\n    profiles: [local]\n    image: admin:latest\n  inspector:\n    profiles:\n      - debug\n    image: inspector:latest\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"
  mkdir -p "${repo}/.github/workflows"
  mkdir -p "${repo}/module-a/src/test/java/com/example"
  java_home="$(detect_java_home)"
  ${CLI} --repo "${repo}" init >/dev/null
  cat > "${repo}/.github/workflows/build.yml" <<'EOF'
jobs:
  build:
    steps:
      - run: ./mvnw -B clean package -Dmaven.build.cache.enabled=false -Dformat.skip=true -DskipTests
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
printf 'LOCAL_CONTAINERS=%s\n' "${LOCAL_CONTAINERS:-}" >> .mvnw.log
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
MAKEVN_FORMAT_CHECK_GOAL=""
MAKEVN_FORMAT_APPLY_GOAL=""
MAKEVN_CHECKSTYLE_GOAL=""
EOF
  local build_output
  local package_output
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" make install >/dev/null
  build_output="$(PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" build)"
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" test-compile >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" compile-tests >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" validate >/dev/null
  package_output="$(PATH="${repo}/fake-bin:${PATH}" rtk make -f .makevn/makevn.mk -C "${repo}" vn-package)"
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" clean >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" test >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" format --apply >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" checkstyle --module module-a --verbose >/dev/null
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
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_BUILD_PROP_FLAGS=-Dformat.skip=true'
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_TEST_PROP_FLAGS=-Dsurefire.failIfNoSpecifiedTests=false'
  assert_not_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_VERIFY_PRE_GOALS=clean'
  assert_contains "${repo}/.makevn/profile.env" 'MAKEVN_PROFILE_VERIFY_PROP_FLAGS=-DfailIfNoTests=false'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml clean package -Dformat\.skip=true -DskipTests$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml test-compile$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml validate$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml clean package -Dformat\.skip=true -DskipTests -Dmaven\.build\.cache\.enabled=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml clean$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml test -Dsurefire\.failIfNoSpecifiedTests=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml com\.example\.format:custom-javaformat-maven-plugin:apply$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml -pl module-a org\.apache\.maven\.plugins:maven-checkstyle-plugin:check -Dcheckstyle\.consoleOutput=true$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml -pl module-a -am test -Dsurefire\.failIfNoSpecifiedTests=false -Dtest=com\.example\.UserRepositoryTest -Dfailsafe\.failIfNoSpecifiedTests=false -Dmaven\.build\.cache\.enabled=true -Dsurefire\.testFailureIgnore=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml -pl module-a -am test -Dsurefire\.failIfNoSpecifiedTests=false -Dtest=com\.example\.OrderRepositoryTest -Dfailsafe\.failIfNoSpecifiedTests=false -Dmaven\.build\.cache\.enabled=true -Dsurefire\.testFailureIgnore=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml -pl module-a -am surefire:test -Dsurefire\.failIfNoSpecifiedTests=false -Dtest=com\.example\.UserRepositoryTest -Dfailsafe\.failIfNoSpecifiedTests=false -Dmaven\.build\.cache\.enabled=true -Dsurefire\.testFailureIgnore=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml -pl module-a -am test-compile failsafe:integration-test -Dsurefire\.failIfNoSpecifiedTests=false -Dit\.test=com\.example\.UserFlowIT -Dfailsafe\.failIfNoSpecifiedTests=false -Dmaven\.build\.cache\.enabled=true$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml verify -DfailIfNoTests=false -Dmaven\.build\.cache\.enabled=false$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"
  assert_contains "${repo}/.mvnw.log" "LOCAL_CONTAINERS="
  assert_not_contains "${repo}/.mvnw.log" "LOCAL_CONTAINERS=TRUE"
  assert_contains "${repo}/exec-java-home.txt" "${java_home}"
  assert_contains "${repo}/run.out" "run-ok"
  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_docker_commands() {
  local repo="${TMP_ROOT}/docker-commands"
  local output

  mkdir -p "${repo}/code/boot/src/main/resources"
  mkdir -p "${repo}/code/boot/src/main/java/com/example"
  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"

  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker-compose %s\n' "$*" >> .docker-compose.log
if [[ "$*" == *" ps -q db" ]]; then
  printf 'abc123def456\n'
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

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" init >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" make install >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" docker-up >/dev/null
  assert_not_contains "${repo}/.docker-compose.log" " ps -q "
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" docker-down >/dev/null
  output="$(rtk make -f .makevn/makevn.mk -C "${repo}" MAKEVN_BIN="${repo}/fake-bin/makevn-wrapper" vn-docker-ps)"

  assert_matches "${repo}/.docker-compose.log" '^docker-compose -f .*/code/boot/src/test/resources/compose/docker-compose\.yml -f .*/code/boot/src/test/resources/compose/docker-compose\.override\.yml down -v --remove-orphans$'
  assert_matches "${repo}/.docker-compose.log" '^docker-compose -f .*/code/boot/src/test/resources/compose/docker-compose\.yml -f .*/code/boot/src/test/resources/compose/docker-compose\.override\.yml up --detach$'
  assert_contains "${repo}/.docker.log" "docker volume prune -f"
  [[ "${output}" == *"fake-db"* ]] || fail "expected docker ps output to include fake container name"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_docker_up_missing_compose_writes_log() {
  local repo="${TMP_ROOT}/docker-up-missing-compose"
  local install_prefix="${TMP_ROOT}/docker-up-missing-compose-install"
  local fail_cli="${install_prefix}/bin/makevn"
  local output_file="${repo}/docker-up.out"

  [[ -x "${ROOT_DIR}/target/release/makevn" ]] || return 0
  PREFIX="${install_prefix}" "${ROOT_DIR}/install.sh" --rust >/dev/null

  mkdir -p "${repo}"

  set +e
  run_makevn_pty_command "${fail_cli}" "${repo}" docker-up "${output_file}"
  local status=$?
  set -e

  [[ ${status} -ne 0 ]] || fail "expected docker-up without compose to fail"
  assert_contains "${output_file}" "[x] docker-up"
  assert_contains "${output_file}" ".makevn/logs/docker-up.log"
  assert_contains "${repo}/.makevn/logs/docker-up.log" "Error: Docker compose file not found."
  assert_contains "${repo}/.makevn/logs/docker-up.log" "command: makevn docker-up"
}

test_docker_ps_required_wait_seconds() {
  local repo="${TMP_ROOT}/docker-ps-required-wait-seconds"
  local java_home
  local invalid_output_file="${repo}/docker-ps-required-invalid.out"

  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  java_home="$(detect_java_home)"

  ${CLI} --repo "${repo}" init >/dev/null
  ${CLI} --repo "${repo}" profile refresh >/dev/null

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
      count_file=".docker-health-count"
      count=0
      if [[ -f "${count_file}" ]]; then
        count="$(cat "${count_file}")"
      fi
      count=$((count + 1))
      printf '%s\n' "${count}" > "${count_file}"
      if (( count < 3 )); then
        printf 'starting\n'
      else
        printf 'healthy\n'
      fi
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

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" docker-ps-required --wait-seconds 5 >/dev/null
  assert_contains "${repo}/.docker.log" "docker inspect -f {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} fake-service-id"

  set +e
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" docker-ps-required --wait-seconds nope >"${invalid_output_file}" 2>&1
  local status=$?
  set -e

  [[ ${status} -ne 0 ]] || fail "expected docker-ps-required --wait-seconds nope to fail"
  assert_contains "${invalid_output_file}" "Invalid value for --wait-seconds: nope. Expected a non-negative integer."

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_karate_commands() {
  local repo="${TMP_ROOT}/karate-commands"
  local java_home
  local output

  mkdir -p "${repo}/code/boot/src/main/resources"
  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/code/boot/target"
  mkdir -p "${repo}/e2e/karate/src/test/resources/compose"
  mkdir -p "${repo}/fake-java-home/bin"
  mkdir -p "${repo}/fake-bin"
  cat > "${repo}/code/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example.parent</groupId>
  <artifactId>parent</artifactId>
  <version>1.0.0</version>
  <packaging>pom</packaging>
  <modules>
    <module>boot</module>
  </modules>
  <properties>
    <java.version>21</java.version>
  </properties>
  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
  <groupId>com.example.productsample</groupId>
</project>
EOF
  cat > "${repo}/code/boot/src/main/resources/application-standalone.yml" <<'EOF'
server:
  context-path: /products
  port: 18080
security:
  ignored-paths: /internal/**
EOF
  printf '<project/>\n' > "${repo}/e2e/karate/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/e2e/karate/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/e2e/karate/src/test/resources/compose/docker-compose.override.yml"
  java_home="$(detect_java_home)"

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
printf 'JAVA_HOME=%s\n' "${JAVA_HOME:-}" >> .mvnw.log
for arg in "$@"; do
  if [[ "${arg}" == "package" ]]; then
    mkdir -p code/boot/target
    printf 'not-a-real-jar\n' > code/boot/target/app.jar
  fi
done
EOF
  chmod +x "${repo}/mvnw"

  cat > "${repo}/fake-java-home/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'JAVA_ARGS=%s\n' "$*" >> .java.log
printf 'LOCAL_CONTAINERS=%s\n' "${LOCAL_CONTAINERS:-}" >> .java.log
if [[ "${1:-}" == "-jar" ]]; then
  trap 'exit 0' TERM INT
  while true; do
    sleep 1
  done
fi
EOF
  chmod +x "${repo}/fake-java-home/bin/java"

  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker-compose %s\n' "$*" >> .docker-compose.log
if [[ "$*" == *" ps -q "* ]]; then
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
if [[ "$1" == "volume" && "${2:-}" == "prune" && "${3:-}" == "-f" ]]; then
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

  cat > "${repo}/fake-bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "\$*" >> "${repo}/.curl.log"
exit 0
EOF
  chmod +x "${repo}/fake-bin/curl"

  cat > "${repo}/fake-bin/makevn-wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="${repo}/fake-bin:\$PATH"
exec "${CLI}" "\$@"
EOF
  chmod +x "${repo}/fake-bin/makevn-wrapper"

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" init >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" make install >/dev/null
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME="${repo}/fake-java-home"
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" karate-docker-up >/dev/null
  assert_not_contains "${repo}/.docker-compose.log" " ps -q "
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" karate-docker-down >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" docker-ps-required --compose karate >/dev/null
  PATH="${repo}/fake-bin:${PATH}" rtk make -f .makevn/makevn.mk -C "${repo}" MAKEVN_BIN="${repo}/fake-bin/makevn-wrapper" vn-docker-ps-required MAKEVN_DOCKER_PS_REQUIRED_ARGS="--compose karate" >/dev/null
  printf 'not-a-real-jar\n' > "${repo}/code/boot/target/app.jar"
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" run-app-bg >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" stop-app >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" karate-test --tag @smoke >/dev/null
  output="$(PATH="${repo}/fake-bin:${PATH}" rtk make -f .makevn/makevn.mk -C "${repo}" MAKEVN_BIN="${repo}/fake-bin/makevn-wrapper" vn-karate-all TAG=@smoke)"

  assert_matches "${repo}/.docker-compose.log" '^docker-compose -f .*/e2e/karate/src/test/resources/compose/docker-compose\.yml -f .*/e2e/karate/src/test/resources/compose/docker-compose\.override\.yml down -v --remove-orphans$'
  assert_matches "${repo}/.docker-compose.log" '^docker-compose -f .*/e2e/karate/src/test/resources/compose/docker-compose\.yml -f .*/e2e/karate/src/test/resources/compose/docker-compose\.override\.yml up --detach$'
  assert_matches "${repo}/.docker-compose.log" '^docker-compose -f .*/e2e/karate/src/test/resources/compose/docker-compose\.yml -f .*/e2e/karate/src/test/resources/compose/docker-compose\.override\.yml ps -q db$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-nsu -f .*/e2e/karate/pom\.xml test -Dkarate\.env=local -Dkarate\.report\.options=--showLog true -Dkarate\.options=-t@smoke$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/code/pom\.xml package -DskipTests -Dmaven\.build\.cache\.enabled=false$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"
  assert_matches "${repo}/.java.log" '^JAVA_ARGS=-jar .*/code/boot/target/app\.jar$'
  assert_contains "${repo}/.curl.log" "http://localhost:18080/products/actuator/health"
  assert_not_exists "${repo}/.makevn/app/app.pid"
  [[ "${output}" == *"[ok] "* ]] || fail "expected vn-karate-all output to include success summary"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_run_app_bg_reports_early_process_exit() {
  local repo="${TMP_ROOT}/run-app-bg-exit"
  local java_home="${repo}/fake-java-home"
  local output=""

  mkdir -p "${repo}/code/boot/src/main/java/com/example"
  mkdir -p "${repo}/code/boot/target"
  mkdir -p "${repo}/fake-java-home/bin"
  mkdir -p "${repo}/fake-bin"
  cat > "${repo}/code/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>sampleapp</artifactId>
  <version>1.0.0</version>
</project>
EOF
  cat > "${repo}/code/boot/src/main/java/com/example/Application.java" <<'EOF'
package com.example;

public class Application {
  public static void main(String[] args) {
  }
}
EOF
  printf 'fake jar\n' > "${repo}/code/boot/target/app.jar"

  cat > "${repo}/fake-java-home/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'startup failed\n' >&2
exit 42
EOF
  chmod +x "${repo}/fake-java-home/bin/java"

  cat > "${repo}/fake-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 7
EOF
  chmod +x "${repo}/fake-bin/curl"

  ${CLI} --repo "${repo}" init >/dev/null
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME="${java_home}"
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  output="$(PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" run-app-bg 2>&1 || true)"

  [[ "${output}" == *"Application process exited during startup"* ]] \
    || fail "expected run-app-bg to report early process exit"
  [[ "${output}" == *"Check the log: "*".makevn/app/app.log"* ]] \
    || fail "expected run-app-bg failure to point to app log"
  [[ "${output}" == *"startup failed"* ]] \
    || fail "expected run-app-bg failure to print an app log excerpt"
  assert_contains "${repo}/.makevn/app/app.log" "startup failed"
  assert_contains "${repo}/.makevn/app/app.log" "java_home: ${java_home}"
  assert_matches "${repo}/.makevn/app/app.log" 'jar: .*/code/boot/target/app\.jar$'
  assert_not_exists "${repo}/.makevn/app/app.pid"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_run_app_bg_packages_when_jar_missing() {
  local repo="${TMP_ROOT}/run-app-bg-packages-missing-jar"
  local java_home="${repo}/fake-java-home"
  local output=""

  mkdir -p "${repo}/code/boot/src/main/java/com/example"
  mkdir -p "${repo}/fake-java-home/bin"
  mkdir -p "${repo}/fake-bin"
  cat > "${repo}/code/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>sampleapp</artifactId>
  <version>1.0.0</version>
</project>
EOF
  cat > "${repo}/code/boot/src/main/java/com/example/Application.java" <<'EOF'
package com.example;

public class Application {
  public static void main(String[] args) {
  }
}
EOF

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
mkdir -p code/boot/target
repo_root="$(pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/makevn-jar.XXXXXX")"
mkdir -p "${tmp_dir}/META-INF"
cat > "${tmp_dir}/META-INF/MANIFEST.MF" <<'MANIFEST'
Manifest-Version: 1.0
Main-Class: org.springframework.boot.loader.launch.JarLauncher
Start-Class: com.example.Application

MANIFEST
(cd "${tmp_dir}" && zip -qr "${repo_root}/code/boot/target/app.jar" META-INF)
rm -rf "${tmp_dir}"
EOF
  chmod +x "${repo}/mvnw"

  cat > "${repo}/fake-java-home/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'JAVA_ARGS=%s\n' "$*" >> .java.log
sleep 30
EOF
  chmod +x "${repo}/fake-java-home/bin/java"

  cat > "${repo}/fake-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 7
EOF
  chmod +x "${repo}/fake-bin/curl"

  ${CLI} --repo "${repo}" init >/dev/null
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME="${java_home}"
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  output="$(PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" run-app-bg 2>&1)"

  [[ "${output}" == *"No packaged application jar found; running 'makevn package' first."* ]] \
    || fail "expected run-app-bg to announce packaging when jar is missing"
  [[ "${output}" == *"ok application started without health check"* ]] \
    || fail "expected run-app-bg to start after packaging"
  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/code/pom\.xml package -DskipTests -Dmaven\.build\.cache\.enabled=false$'
  assert_matches "${repo}/.java.log" '^JAVA_ARGS=-jar .*/code/boot/target/app\.jar$'
  assert_contains "${repo}/.makevn/app/app.log" "start_class: com.example.Application"

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" stop-app >/dev/null
  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_run_app_bg_prefers_executable_jar_candidate() {
  local repo="${TMP_ROOT}/run-app-bg-executable-jar"
  local java_home="${repo}/fake-java-home"

  mkdir -p "${repo}/code/boot/target"
  mkdir -p "${repo}/fake-java-home/bin"
  mkdir -p "${repo}/fake-bin"
  cat > "${repo}/code/pom.xml" <<'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>sampleapp</artifactId>
  <version>1.0.0</version>
</project>
EOF
  make_test_jar_with_manifest "${repo}/code/boot/target/aaa-plain.jar" ""
  make_test_jar_with_manifest "${repo}/code/boot/target/zzz-app.jar" "org.springframework.boot.loader.launch.JarLauncher" "com.example.Application"

  cat > "${repo}/fake-java-home/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'JAVA_ARGS=%s\n' "$*" >> .java.log
sleep 30
EOF
  chmod +x "${repo}/fake-java-home/bin/java"

  cat > "${repo}/fake-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${repo}/fake-bin/curl"

  ${CLI} --repo "${repo}" init >/dev/null
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME="${java_home}"
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" run-app-bg >/dev/null

  for _ in 1 2 3 4 5; do
    [[ -f "${repo}/.java.log" ]] && break
    sleep 1
  done
  assert_matches "${repo}/.java.log" '^JAVA_ARGS=-jar .*/code/boot/target/zzz-app\.jar$'
  assert_contains "${repo}/.makevn/app/app.log" "main_class: org.springframework.boot.loader.launch.JarLauncher"
  assert_contains "${repo}/.makevn/app/app.log" "start_class: com.example.Application"

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" stop-app >/dev/null
  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_run_app_bg_uses_tool_versions_jdk_before_global_fallback() {
  local repo="${TMP_ROOT}/run-app-bg-tool-versions-jdk"
  local output=""

  mkdir -p "${repo}/code/boot/src/main/resources"
  mkdir -p "${repo}/code/boot/src/main/java/com/example"
  mkdir -p "${repo}/code/boot/target"
  mkdir -p "${repo}/fake-code-java-home/bin"
  mkdir -p "${repo}/wrong-java-home/bin"
  mkdir -p "${repo}/fake-bin"

  printf '<project/>\n' > "${repo}/code/pom.xml"
  cat > "${repo}/code/boot/src/main/java/com/example/Application.java" <<'EOF'
package com.example;

public class Application {
  public static void main(String[] args) {
  }
}
EOF
  printf 'ivm-java zulu-21.0.1\n' > "${repo}/code/.tool-versions"
  printf 'server:\n  port: 18082\n' > "${repo}/code/boot/src/main/resources/application.yml"
  printf 'fake jar\n' > "${repo}/code/boot/target/app.jar"

  cat > "${repo}/fake-code-java-home/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-version" ]]; then
  printf 'openjdk version "21.0.1"\n' >&2
  exit 0
fi
printf 'JAVA_HOME=%s\n' "${JAVA_HOME:-}" >> .java.log
printf 'JAVA_ARGS=%s\n' "$*" >> .java.log
if [[ "${1:-}" == "-jar" ]]; then
  trap 'exit 0' TERM INT
  while true; do
    sleep 1
  done
fi
EOF
  chmod +x "${repo}/fake-code-java-home/bin/java"

  cat > "${repo}/wrong-java-home/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-version" ]]; then
  printf 'openjdk version "17.0.1"\n' >&2
  exit 0
fi
printf 'wrong java selected\n' >> .java.log
exit 64
EOF
  chmod +x "${repo}/wrong-java-home/bin/java"

  cat > "${repo}/fake-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${repo}/fake-bin/curl"

  JAVA_HOME="${repo}/fake-code-java-home" ${CLI} --repo "${repo}" init >/dev/null
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${repo}/wrong-java-home"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
EOF

  output="$(JAVA_HOME="${repo}/fake-code-java-home" PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" run-app-bg 2>&1)"

  assert_contains "${repo}/.java.log" "JAVA_HOME=${repo}/fake-code-java-home"
  assert_matches "${repo}/.java.log" '^JAVA_ARGS=-jar .*/code/boot/target/app\.jar$'
  [[ "${output}" == *"ok application started without health check"* ]] || fail "expected run-app-bg to start with the tool-versions JDK"

  JAVA_HOME="${repo}/fake-code-java-home" ${CLI} --repo "${repo}" stop-app >/dev/null
  JAVA_HOME="${repo}/fake-code-java-home" ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_karate_all_rust_frontend_reports_run_app_bg_failure() {
  local repo="${TMP_ROOT}/karate-all-run-app-bg-failure"
  local install_prefix="${TMP_ROOT}/karate-all-run-app-bg-failure-install"
  local rust_cli="${install_prefix}/bin/makevn"
  local output_file="${TMP_ROOT}/karate-all-run-app-bg-failure.out"
  local clean_output_file="${TMP_ROOT}/karate-all-run-app-bg-failure.clean.out"

  [[ -x "${ROOT_DIR}/target/release/makevn" ]] || return 0
  PREFIX="${install_prefix}" "${ROOT_DIR}/install.sh" --rust >/dev/null

  mkdir -p "${repo}/code/boot/src/main/resources"
  mkdir -p "${repo}/code/boot/src/main/java/com/example"
  mkdir -p "${repo}/code/boot/target"
  mkdir -p "${repo}/e2e/karate/src/test/resources/compose"
  mkdir -p "${repo}/fake-java-home/bin"
  mkdir -p "${repo}/fake-bin"

  printf '<project/>\n' > "${repo}/code/pom.xml"
  cat > "${repo}/code/boot/src/main/java/com/example/Application.java" <<'EOF'
package com.example;

public class Application {
  public static void main(String[] args) {
  }
}
EOF
  printf '<project/>\n' > "${repo}/e2e/karate/pom.xml"
  printf 'server:\n  port: 18081\n' > "${repo}/code/boot/src/main/resources/application.yml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/e2e/karate/src/test/resources/compose/docker-compose.yml"
  printf 'fake jar\n' > "${repo}/code/boot/target/app.jar"

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "${arg}" == "package" ]]; then
    mkdir -p code/boot/target
    printf 'fake jar\n' > code/boot/target/app.jar
  fi
done
EOF
  chmod +x "${repo}/mvnw"

  cat > "${repo}/fake-java-home/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'app startup failed\n' >&2
exit 42
EOF
  chmod +x "${repo}/fake-java-home/bin/java"

  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *" ps -q "* ]]; then
  printf 'fake-service-id\n'
fi
EOF
  chmod +x "${repo}/fake-bin/docker-compose"

  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "volume" ]]; then
  exit 0
fi
if [[ "${1:-}" == "inspect" && "${2:-}" == "-f" ]]; then
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
  esac
fi
EOF
  chmod +x "${repo}/fake-bin/docker"

  cat > "${repo}/fake-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 7
EOF
  chmod +x "${repo}/fake-bin/curl"

  "${rust_cli}" --repo "${repo}" init >/dev/null
  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${repo}/fake-java-home"
MAKEVN_CODE_JAVA_HOME="${repo}/fake-java-home"
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
MAKEVN_APP_HEALTH_TIMEOUT=5
EOF

  PATH="${repo}/fake-bin:${PATH}" script -q /dev/null bash -lc "\"${rust_cli}\" --repo \"${repo}\" karate-all" > "${output_file}" 2>&1 || true
  tr -d '\r' < "${output_file}" > "${clean_output_file}"

  assert_contains "${clean_output_file}" "[x] run-app-bg"
  assert_contains "${clean_output_file}" ".makevn/app/app.log"
  assert_not_contains "${clean_output_file}" "[x] karate-docker-up"
  assert_contains "${repo}/.makevn/app/app.log" "app startup failed"
  assert_not_exists "${repo}/.makevn/app/app.pid"

  "${rust_cli}" --repo "${repo}" uninstall >/dev/null
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

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" init >/dev/null
  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" make install >/dev/null
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

  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml verify -Djacoco\.skip=false -DskipITs -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml verify -Djacoco\.skip=false -DskipUTs -Dskip\.unit\.tests=true -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false -Dmaven\.build\.cache\.enabled=false$'
  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml clean verify -Djacoco\.skip=false -DskipITs -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false -Dmaven\.build\.cache\.enabled=false$'
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

  ${CLI} --repo "${repo}" init >/dev/null
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
      - run: mvn -B -nsu clean verify -DskipITs -DfailIfNoTests=false -Dformat.skip=true
EOF

  ${CLI} --repo "${repo}" init >/dev/null
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

  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -nsu -f .*/pom\.xml verify -DfailIfNoTests=false -Dformat\.skip=true -Djacoco\.skip=false -DskipUTs -Dskip\.unit\.tests=true -Dmaven\.test\.failure\.ignore=false -Dmaven\.build\.cache\.enabled=false$'
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
      - run: mvn -B -nsu install -Djacoco.skip=false -Dcoverage.profile=true -DskipUTs -Dskip.unit.tests=true -DfailIfNoTests=false -Dmaven.test.failure.ignore=false
EOF

  ${CLI} --repo "${repo}" init >/dev/null
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

  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml -B -nsu verify -Djacoco\.skip=false -Dcoverage\.profile=true -DskipUTs -Dskip\.unit\.tests=true -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false -Dmaven\.build\.cache\.enabled=false$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"
  assert_contains "${repo}/.mvnw.log" "LOCAL_CONTAINERS=TRUE"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_verify_respects_local_containers_config() {
  local repo="${TMP_ROOT}/verify-local-containers-config"
  local java_home

  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  java_home="$(detect_java_home)"

  ${CLI} --repo "${repo}" init >/dev/null

  cat > "${repo}/.makevn/config" <<EOF
MAKEVN_JAVA_HOME="${java_home}"
MAKEVN_CODE_JAVA_HOME=""
MAKEVN_KARATE_JAVA_HOME=""
MAKEVN_CODE_TOOL_VERSIONS=""
MAKEVN_KARATE_TOOL_VERSIONS=""
MAKEVN_RUN_CMD=""
MAKEVN_LOCAL_CONTAINERS=""
EOF

  cat > "${repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ARGS=%s\n' "$*" >> .mvnw.log
printf 'LOCAL_CONTAINERS=%s\n' "${LOCAL_CONTAINERS:-}" >> .mvnw.log
EOF
  chmod +x "${repo}/mvnw"

  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-f" ]]; then
  printf 'fake-service-id\n'
fi
EOF
  chmod +x "${repo}/fake-bin/docker-compose"
  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify >/dev/null
  assert_contains "${repo}/.mvnw.log" "LOCAL_CONTAINERS="
  assert_not_contains "${repo}/.mvnw.log" "LOCAL_CONTAINERS=TRUE"

  rm -f "${repo}/.mvnw.log"
  LOCAL_CONTAINERS=FALSE PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify >/dev/null
  assert_contains "${repo}/.mvnw.log" "LOCAL_CONTAINERS=FALSE"

  ${CLI} --repo "${repo}" uninstall >/dev/null
}

test_verify_leaves_local_containers_unset_without_repo_signal() {
  local repo="${TMP_ROOT}/verify-local-containers-unset"
  local java_home

  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  java_home="$(detect_java_home)"

  ${CLI} --repo "${repo}" init >/dev/null

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
printf 'LOCAL_CONTAINERS=%s\n' "${LOCAL_CONTAINERS:-}" >> .mvnw.log
EOF
  chmod +x "${repo}/mvnw"

  cat > "${repo}/fake-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-f" ]]; then
  printf 'fake-service-id\n'
fi
EOF
  chmod +x "${repo}/fake-bin/docker-compose"
  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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

  PATH="${repo}/fake-bin:${PATH}" ${CLI} --repo "${repo}" verify >/dev/null
  assert_contains "${repo}/.mvnw.log" "LOCAL_CONTAINERS="
  assert_not_contains "${repo}/.mvnw.log" "LOCAL_CONTAINERS=TRUE"

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

  ${CLI} --repo "${repo}" init >/dev/null
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
  assert_matches "${repo}/.mvnw.log" '^ARGS=-nsu -f .*/pom\.xml verify -Djacoco\.skip=false -DskipUTs=false -Dtest=com\.example\.ChangedTest -Dit\.test=com\.example\.ChangedTest -Dfailsafe\.failIfNoSpecifiedTests=false -Dsurefire\.failIfNoSpecifiedTests=false -Dawaitility\.defaultPollInterval=200ms -Dawaitility\.defaultTimeout=2m -Dmaven\.build\.cache\.enabled=false$'
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

  [[ "${output}" == *"✓  changed lines    100.00%  1/1"* ]] \
    || fail "expected coverage-changes output to pass incremental coverage"
  [[ "${output}" == *"Quality gate conditions met"* ]] \
    || fail "expected coverage-changes output to include overall quality gate"
}

test_coverage_changes_fails_changed_module_gate() {
  local repo="${TMP_ROOT}/coverage-changes-module-gate"
  local output

  mkdir -p "${repo}/module-a/src/main/java/com/example"
  mkdir -p "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/com.example"
  printf '<project/>\n' > "${repo}/pom.xml"

  cat > "${repo}/module-a/src/main/java/com/example/Changed.java" <<'EOF'
package com.example;

class Changed {
  int value() {
    int oldUntouchedLine = 0;
    return 0;
  }
}
EOF

  cat > "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/com.example/Changed.java.html" <<'EOF'
<html><body>
<span class="nc" id="L5">    int oldUntouchedLine = 0;</span>
<span class="fc" id="L6">    return 1;</span>
</body></html>
EOF

  cat > "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/jacoco.csv" <<'EOF'
GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED
root/module-a,com.example,Changed,50,50,0,0,1,1,0,1,0,1
EOF
  printf '<html></html>\n' > "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/index.html"

  rtk git init "${repo}" >/dev/null
  rtk git -C "${repo}" add .
  rtk git -C "${repo}" -c user.name='Smoke Test' -c user.email='smoke@example.com' commit -m 'init' >/dev/null
  perl -0pi -e 's/return 0;/return 1;/' "${repo}/module-a/src/main/java/com/example/Changed.java"

  output="$(${CLI} --repo "${repo}" coverage-changes --threshold 90 2>&1 || true)"

  [[ "${output}" == *"✓  changed lines    100.00%  1/1"* ]] \
    || fail "expected line-level incremental coverage to pass"
  [[ "${output}" == *"✗  module-a"* && "${output}" == *"50.00%"* ]] \
    || fail "expected changed module coverage to report failing module"
  [[ "${output}" == *"├  Top offenders"* ]] \
    || fail "expected changed module coverage to include top offenders"
  [[ "${output}" == *"changed module coverage gate not met"* ]] \
    || fail "expected coverage-changes to fail the changed module gate"
}

test_coverage_changes_ignores_diff_context_lines() {
  local repo="${TMP_ROOT}/coverage-changes-context-lines"
  local output

  mkdir -p "${repo}/module-a/src/main/java/com/example"
  mkdir -p "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/com.example"
  printf '<project/>\n' > "${repo}/pom.xml"

  cat > "${repo}/module-a/src/main/java/com/example/Changed.java" <<'EOF'
package com.example;

class Changed {
  int value() {
    int missedContext = 0;
    return 0;
  }
}
EOF

  cat > "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/com.example/Changed.java.html" <<'EOF'
<html><body>
<span class="nc" id="L5">    int missedContext = 0;</span>
<span class="fc" id="L6">    return 1;</span>
</body></html>
EOF

  cat > "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/jacoco.csv" <<'EOF'
GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED
makevn,com.example,Changed,1,10,0,0,1,1,0,1,0,1
EOF
  printf '<html></html>\n' > "${repo}/jacoco-report-aggregate/target/site/jacoco-aggregate/index.html"

  rtk git init "${repo}" >/dev/null
  rtk git -C "${repo}" add .
  rtk git -C "${repo}" -c user.name='Smoke Test' -c user.email='smoke@example.com' commit -m 'init' >/dev/null
  perl -0pi -e 's/return 0;/return 1;/' "${repo}/module-a/src/main/java/com/example/Changed.java"

  output="$(${CLI} --repo "${repo}" coverage-changes --threshold 50)"

  [[ "${output}" == *"✓  changed lines    100.00%  1/1"* ]] \
    || fail "expected coverage-changes to ignore uncovered diff context lines"
}

test_coverage_accepts_decimal_above_threshold() {
  local repo="${TMP_ROOT}/coverage-decimal-threshold"
  local output

  mkdir -p "${repo}/target/site/jacoco"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf '<html></html>\n' > "${repo}/target/site/jacoco/index.html"
  cat > "${repo}/target/site/jacoco/jacoco.csv" <<'EOF'
GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED
makevn,com.example,Changed,2239,7820,0,0,0,1,0,1,0,1
EOF
  mkdir -p "${repo}/.makevn"
  cat > "${repo}/.makevn/config" <<'EOF'
MAKEVN_MIN_COVERAGE_THRESHOLD="70 (from config)"
EOF

  output="$(${CLI} --repo "${repo}" coverage)"

  [[ "${output}" == *"Coverage: 77.74 %"* ]] || fail "expected coverage output to report decimal coverage"
  [[ "${output}" == *"Quality gate conditions met"* ]] || fail "expected coverage to pass when decimal coverage is above threshold"
}

test_coverage_combines_module_reports() {
  local repo="${TMP_ROOT}/coverage-module-reports"
  local output

  mkdir -p "${repo}/module-a/target/site/jacoco" "${repo}/module-b/target/site/jacoco"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf '<html></html>\n' > "${repo}/module-a/target/site/jacoco/index.html"
  printf '<html></html>\n' > "${repo}/module-b/target/site/jacoco/index.html"
  cat > "${repo}/module-a/target/site/jacoco/jacoco.csv" <<'EOF'
GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED
makevn,com.example,A,20,80,0,0,0,1,0,1,0,1
EOF
  cat > "${repo}/module-b/target/site/jacoco/jacoco.csv" <<'EOF'
GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED
makevn,com.example,B,30,70,0,0,0,1,0,1,0,1
EOF

  output="$(${CLI} --repo "${repo}" coverage --threshold 74)"

  [[ "${output}" == *"Coverage: 75.00 %"* ]] || fail "expected coverage output to combine module CSV reports"
  [[ "${output}" == *"Quality gate conditions met"* ]] || fail "expected combined module coverage to pass"
}

test_coverage_generates_module_reports_when_missing() {
  local repo="${TMP_ROOT}/coverage-generate-module-reports"
  local java_home
  local output

  mkdir -p "${repo}"
  printf '<project/>\n' > "${repo}/pom.xml"
  java_home="$(detect_java_home)"
  mkdir -p "${repo}/.makevn"
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
printf 'ARGS=%s\n' "$*" >> .mvnw.log
mkdir -p module-a/target/site/jacoco
printf '<html></html>\n' > module-a/target/site/jacoco/index.html
cat > module-a/target/site/jacoco/jacoco.csv <<'CSV'
GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED
makevn,com.example,A,20,80,0,0,0,1,0,1,0,1
CSV
EOF
  chmod +x "${repo}/mvnw"

  output="$(${CLI} --repo "${repo}" coverage --threshold 80)"

  assert_matches "${repo}/.mvnw.log" '^ARGS=-nsu -f .*/pom\.xml jacoco:report -Dmaven\.build\.cache\.enabled=false$'
  [[ "${output}" == *"Coverage report not found; attempting jacoco:report"* ]] || fail "expected coverage to generate missing Jacoco report"
  [[ "${output}" == *"Quality gate conditions met"* ]] || fail "expected generated module coverage to pass"
}

test_coverage_uses_detected_activation_profile() {
  local repo="${TMP_ROOT}/coverage-activation-profile"
  local java_home
  local output

  mkdir -p "${repo}/.github/workflows"
  printf '<project><profiles><profile><id>jacoco</id></profile></profiles></project>\n' > "${repo}/pom.xml"
  cat > "${repo}/.github/workflows/test.yml" <<'EOF'
jobs:
  test:
    steps:
      - run: ./mvnw -B install -Pjacoco
EOF
  java_home="$(detect_java_home)"
  mkdir -p "${repo}/.makevn"
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
printf 'ARGS=%s\n' "$*" >> .mvnw.log
case "$*" in
  *" verify "*)
    mkdir -p target/site/jacoco
    printf '<html></html>\n' > target/site/jacoco/index.html
    cat > target/site/jacoco/jacoco.csv <<'CSV'
GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED
makevn,com.example,A,20,80,0,0,0,1,0,1,0,1
CSV
    ;;
esac
EOF
  chmod +x "${repo}/mvnw"

  ${CLI} --repo "${repo}" doctor >/dev/null
  output="$(${CLI} --repo "${repo}" coverage --threshold 80)"

  assert_matches "${repo}/.mvnw.log" '^ARGS=-B -f .*/pom\.xml verify -Pjacoco -Djacoco\.skip=false -DskipITs -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false$'
  [[ "${output}" == *"Quality gate conditions met"* ]] || fail "expected coverage to pass with detected activation profile"
}

test_coverage_fails_early_without_jacoco_strategy() {
  local repo="${TMP_ROOT}/coverage-no-jacoco-strategy"
  local java_home
  local output

  mkdir -p "${repo}/.makevn"
  printf '<project/>\n' > "${repo}/pom.xml"
  java_home="$(detect_java_home)"
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
printf 'ARGS=%s\n' "$*" >> .mvnw.log
EOF
  chmod +x "${repo}/mvnw"

  output="$(${CLI} --repo "${repo}" coverage 2>&1 || true)"

  [[ ! -f "${repo}/.mvnw.log" ]] || fail "expected coverage not to invoke Maven without a detectable JaCoCo strategy"
  [[ "${output}" == *"No JaCoCo activation or jacoco-maven-plugin declaration detected"* ]] \
    || fail "expected coverage to fail early with a clear JaCoCo strategy message"
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

test_verify_split_commands_reject_wrong_skip_flags() {
  local repo="${TMP_ROOT}/verify-split-reject-skips"
  local output=""

  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"

  ${CLI} --repo "${repo}" init >/dev/null

  output="$(${CLI} --repo "${repo}" verify-ut -- -DskipUTs 2>&1 || true)"
  [[ "${output}" == *"verify-ut must not skip unit tests"* ]] \
    || fail "expected verify-ut to reject UT skip flags"

  output="$(${CLI} --repo "${repo}" verify-it -- -DskipITs 2>&1 || true)"
  [[ "${output}" == *"verify-it must not skip integration tests"* ]] \
    || fail "expected verify-it to reject IT skip flags"

  ${CLI} --repo "${repo}" uninstall >/dev/null
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

  "${seq_cli}" --repo "${repo}" init >/dev/null

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
  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml verify -Djacoco\.skip=false -DskipUTs -Dskip\.unit\.tests=true -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false -Dmaven\.build\.cache\.enabled=false$'
  assert_contains "${repo}/.mvnw.log" "JAVA_HOME=${java_home}"

  "${seq_cli}" --repo "${repo}" uninstall >/dev/null
}

test_shell_entrypoint_sequential_commands() {
  local repo="${TMP_ROOT}/shell-sequential-commands"
  local install_prefix="${TMP_ROOT}/shell-sequential-install"
  local seq_cli="${install_prefix}/bin/makevn"
  local java_home

  PREFIX="${install_prefix}" "${ROOT_DIR}/install.sh" --shell >/dev/null

  mkdir -p "${repo}"
  mkdir -p "${repo}/code/boot/src/test/resources/compose"
  mkdir -p "${repo}/fake-bin"
  printf '<project/>\n' > "${repo}/pom.xml"
  printf 'services:\n  db:\n    image: postgres:16\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.yml"
  printf 'services:\n  db:\n    environment:\n      FOO: bar\n' > "${repo}/code/boot/src/test/resources/compose/docker-compose.override.yml"
  java_home="$(detect_java_home)"

  "${seq_cli}" --repo "${repo}" init >/dev/null

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
printf 'fake-service-id\n'
EOF
  chmod +x "${repo}/fake-bin/docker-compose"
  cat > "${repo}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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
  assert_matches "${repo}/.mvnw.log" '^ARGS=-f .*/pom\.xml verify -Djacoco\.skip=false -DskipUTs -Dskip\.unit\.tests=true -DfailIfNoTests=false -Dmaven\.test\.failure\.ignore=false -Dmaven\.build\.cache\.enabled=false$'
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

  "${fail_cli}" --repo "${repo}" init >/dev/null
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
  test_doctor_resolves_java_version_from_pom
  test_doctor_resolves_java_version_from_pom_property_reference
  test_doctor_resolves_java_version_from_compiler_plugin_source
  test_doctor_does_not_invent_health_check
  test_doctor_detects_actuator_health_check
  test_doctor_shows_progress_in_tty
  test_doctor_reports_compatible_newer_java_homes
  test_exec_uses_compatible_newer_java_home
  test_run_app_bg_disabled_without_executable_app
  test_standalone_mode
  test_init_force_preserves_config
  test_format_requires_configured_formatter
  test_checkstyle_requires_configured_plugin
  test_make_install_existing_makefile
  test_make_install_without_makefile
  test_installer
  test_init_does_not_touch_existing_makefile
  test_profile_refresh
  test_interactive_pid_output
  test_interactive_ctrl_c_interrupt
  test_make_failure_output
  test_tail_degrades_without_tty
  test_non_tty_run_is_compact_and_keeps_full_log_in_file
  test_command_routing
  test_docker_commands
  test_docker_up_missing_compose_writes_log
  test_docker_ps_required_wait_seconds
  test_karate_commands
  test_run_app_bg_reports_early_process_exit
  test_run_app_bg_packages_when_jar_missing
  test_run_app_bg_prefers_executable_jar_candidate
  test_run_app_bg_uses_tool_versions_jdk_before_global_fallback
  test_karate_all_rust_frontend_reports_run_app_bg_failure
  test_verify_split_commands
  test_verify_it_requires_running_services
  test_verify_it_uses_verify_lifecycle_when_verify_workflow_skips_it
  test_verify_it_prefers_integration_workflow_when_available
  test_verify_respects_local_containers_config
  test_verify_leaves_local_containers_unset_without_repo_signal
  test_verify_changes_command
  test_coverage_changes_command
  test_coverage_changes_fails_changed_module_gate
  test_coverage_changes_ignores_diff_context_lines
  test_coverage_accepts_decimal_above_threshold
  test_coverage_combines_module_reports
  test_coverage_generates_module_reports_when_missing
  test_coverage_uses_detected_activation_profile
  test_coverage_fails_early_without_jacoco_strategy
  test_verify_rejects_skip_flags
  test_verify_split_commands_reject_wrong_skip_flags
  test_sequential_commands
  test_shell_entrypoint_sequential_commands
  test_command_typo_rejected_before_backend
  test_command_failure_summary_omits_duplicate_elapsed
  printf 'Smoke tests passed\n'
}

main "$@"
