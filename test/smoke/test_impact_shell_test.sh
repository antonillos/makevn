#!/usr/bin/env bash
set -euo pipefail
export SHELLOPTS
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="${ROOT}/libexec/makevn"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/commands/test_impact.sh"
fixture_java_home="$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^[[:space:]]*java.home = //p')"
major="$("${fixture_java_home}/bin/java" -version 2>&1 | sed -nE 's/.*version "([0-9]+).*/\1/p' | head -1)"
if [[ ! "${major}" =~ ^[0-9]+$ || "${major}" -lt 17 ]]; then
  printf 'Test impact shell capture requires JDK 17+; skipped\n'
  exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
git -C "${tmp}" init -q
git -C "${tmp}" -c user.name=Test -c user.email=test@example.test commit --allow-empty --no-gpg-sign -qm fixture
python3 - "${tmp}" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
(root / 'pom.xml').write_text('<project/>')
for name in ['Owner', 'Other', 'OwnerTest', 'OtherTest', 'OptionalTest']:
    kind = 'test' if name.endswith('Test') else 'main'
    path = root / ('src/' + kind + '/java/example/' + name + '.java')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('package example; class ' + name + ' {}')
    target = root / ('target/' + ('test-classes' if kind == 'test' else 'classes') + '/example/' + name + '.class')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b'fixture bytecode')
PY
mkdir -p "${tmp}/.makevn"
stamp="$(mktemp "${tmp}/.makevn/stamp.XXXXXX")"
mkdir -p "${tmp}/target/surefire-reports"
for name in OwnerTest OtherTest; do
  printf '<testsuite><testcase classname="example.%s"/></testsuite>' "${name}" > "${tmp}/target/surefire-reports/TEST-${name}.xml"
done
printf '<testsuite><testcase classname="example.OptionalTest"><skipped message="live test disabled"/></testcase></testsuite>' > "${tmp}/target/surefire-reports/TEST-OptionalTest.xml"
MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH="${tmp}"
MAKEVN_TEST_IMPACT_CAPTURE=true
MAKEVN_FOCUSED_PHASE_INDEX=2
makevn_effective_java_home() { printf '%s\n' "${fixture_java_home}"; }
makevn_verify_focused_owner() {
  [[ "${FAIL_CLASS:-false}" != true ]] || return 7
  printf '%s\n' "$3" >> "${tmp}/.makevn/isolated-calls"
  local options="$5" name="$3" traces
  traces="${options##*file=}"
  traces="${traces%%/%p.log*}"
  printf '[0.1s][info][class,load] %s source: file:/fixture/test-classes/\n' "${name}" > "${traces}/123.log"
  printf '[0.1s][info][class,load] %s source: file:/fixture/classes/\n' "${name%Test}" >> "${traces}/123.log"
}
makevn_capture_test_impact "${tmp}" "${stamp}"
python3 - "${tmp}/.makevn/test-impact/map.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value['status'] == 'success'
assert set(value['records']) == {'example.OwnerTest', 'example.OtherTest'}
assert value['skipped'] == {'example.OptionalTest': ['live test disabled']}
PY
# Resume a sealed partial checkpoint, then fail its remaining class.
python3 - "${tmp}" "${SCRIPT_DIR}/common" <<'PYTEST'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[2])
import test_impact as impact
root = Path(sys.argv[1])
value = impact.sealed_load(root / '.makevn/test-impact/capture.json')
value['records'].pop('example.OtherTest')
impact.sealed_save(root / '.makevn/test-impact/capture.json', value)
PYTEST
FAIL_CLASS=true
if makevn_capture_test_impact "${tmp}" "${stamp}"; then exit 1; fi
[[ "$(cat "${tmp}/.makevn/test-impact/map.json")" == *'"status": "pending"'* ]]
! find "${tmp}/.makevn/test-impact" -name 'traces.*' | grep -q .
FAIL_CLASS=false
makevn_capture_test_impact "${tmp}" "${stamp}"
[[ "$(wc -l < "${tmp}/.makevn/isolated-calls" | tr -d ' ')" == 3 ]]
MAKEVN_TEST_IMPACT_CAPTURE=false
makevn_capture_test_impact "${tmp}" "${stamp}"

# Optional classes still require fresh reports; activation failures cannot pass.
python3 "${SCRIPT_DIR}/common/selected_test_reports.py" "${tmp}" example.OptionalTest "${stamp}" "${tmp}"
printf '<testsuite><testcase classname="example.OptionalTest"><failure/></testcase></testsuite>' > "${tmp}/target/surefire-reports/TEST-OptionalTest.xml"
if python3 "${SCRIPT_DIR}/common/selected_test_reports.py" "${tmp}" example.OptionalTest "${stamp}" "${tmp}"; then exit 1; fi
printf 'Test impact shell capture, optional reports and failure invalidation passed\n'
