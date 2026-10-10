#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAKEVN_LIBEXEC_DIR="${ROOT}/libexec/makevn"
source "${ROOT}/libexec/makevn/commands/scoped_coverage.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
makevn_state_dir() { printf '%s/.makevn\n' "$1"; }
makevn_maven_executable() { [[ $# == 2 ]]; printf 'mvn\n'; }
makevn_effective_java_home() { [[ $# == 3 && "$2" == code ]]; printf '%s\n' "${tmp}/jdk"; }
git init -q "${tmp}"
git -C "${tmp}" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm base
MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH="${tmp}"
MAKEVN_VERIFY_CHANGES_MODULE_SELECTION=client
MAKEVN_VERIFY_CHANGES_PARENT_SPEC=HEAD
MAKEVN_VERIFY_CHANGES_SRC_FILES=client/src/main/java/example/Owner.java
mkdir -p "${tmp}/client/src/main/java/example" "${tmp}/client/target/classes/example" "${tmp}/jdk/bin"
printf 'class Owner {}' > "${tmp}/${MAKEVN_VERIFY_CHANGES_SRC_FILES}"
printf bytecode > "${tmp}/client/target/classes/example/Owner.class"
makevn_scoped_coverage_prepare "${tmp}"
printf data > "${tmp}/client/target/jacoco.exec"
makevn_scoped_coverage_finish "${tmp}"
touch "$(makevn_scoped_coverage_state "${tmp}")/org.jacoco.cli-0.8.14-nodeps.jar"
cat > "${tmp}/jdk/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
 case "$1" in
  --xml) xml="$2"; shift 2;;
  --csv) csv="$2"; shift 2;;
  --html) html="$2"; shift 2;;
  *) shift;;
 esac
done
printf '<report><package name="example"><class name="example/Owner"/></package></report>' > "${xml}"
printf 'GROUP,PACKAGE,CLASS\nfocused,example,Owner\n' > "${csv}"
printf html > "${html}/index.html"
EOF
chmod +x "${tmp}/jdk/bin/java"
report="$(makevn_scoped_coverage_report "${tmp}" "${tmp}")"
[[ -f "${report}/jacoco.xml" ]]
grep -q 'client,example,Owner' "${report}/jacoco.csv"
[[ "$(makevn_scoped_coverage_report "${tmp}" "${tmp}" HEAD)" == "${report}" ]]
printf 'changed' >> "${tmp}/${MAKEVN_VERIFY_CHANGES_SRC_FILES}"
if makevn_scoped_coverage_report "${tmp}" "${tmp}" > "${tmp}/failure" 2>&1; then exit 1; fi
grep -q 'sources/config changed' "${tmp}/failure"
printf 'Scoped coverage shell coordination passed\n'
# Exercise both command entry points against the same report, never a stale aggregate.
SCRIPT_DIR="${MAKEVN_LIBEXEC_DIR}"
source "${ROOT}/libexec/makevn/commands/changes.sh"
source "${ROOT}/libexec/makevn/commands/crap.sh"
makevn_effective_coverage_changes_threshold() { printf 90; }
makevn_effective_coverage_threshold() { printf 90; }
makevn_frontend_owns_loader() { return 0; }
makevn_detect_maven_base_path() { printf '%s\n' "$1"; }
makevn_detect_parent_branch_spec() { printf HEAD; }
makevn_print_detail_line() { printf '%s\n' "$*"; }
makevn_internal_make_script_path() { printf '%s\n' "${tmp}/coverage-gate.sh"; }
cat > "${tmp}/coverage-gate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${MAKEVN_COVERAGE_SCOPED}" == true && -f "$1/jacoco.xml" ]]
printf 'coordinated coverage gate\n'
EOF
# Restore source content so the original successful snapshot becomes valid.
printf 'class Owner {}' > "${tmp}/${MAKEVN_VERIFY_CHANGES_SRC_FILES}"
output="$(cmd_coverage_changes "${tmp}")"
[[ "${output}" == *'coordinated coverage gate'* ]]
makevn_die() { printf '%s\n' "$*" >&2; exit 1; }
if (cmd_coverage_changes "${tmp}" --overall-threshold 90) > "${tmp}/overall" 2>&1; then exit 1; fi
grep -q 'requires a full coverage report' "${tmp}/overall"
MAKEVN_CRAP_THRESHOLD=8
makevn_load_config() { :; }
makevn_crap_cache_jar() { printf '%s\n' "${tmp}/missing-analyzer.jar"; }
if output="$(makevn_crap_run "${tmp}" crap-changes 2>&1)"; then exit 1; fi
[[ "${output}" == *'using focused UT/IT coverage'* ]]
[[ "${output}" == *'crap4java is not installed'* ]]
[[ -f "${report}/jacoco.xml" ]]
printf 'Coverage/CRAP command coordination passed\n'

makevn_effective_java_home() { printf ''; }
if makevn_scoped_coverage_report "${tmp}" "${tmp}" > "${tmp}/jdk-failure" 2>&1; then exit 1; fi
grep -q 'configured code JDK is required' "${tmp}/jdk-failure"
