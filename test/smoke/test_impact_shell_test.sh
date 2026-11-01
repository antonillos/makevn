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
for name in ['Owner', 'Other', 'OwnerTest', 'OtherTest']:
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
MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH="${tmp}"
MAKEVN_TEST_IMPACT_CAPTURE=true
MAKEVN_FOCUSED_PHASE_INDEX=2
makevn_effective_java_home() { printf '%s\n' "${fixture_java_home}"; }
makevn_verify_focused_owner() {
  [[ "${FAIL_CLASS:-false}" != true ]] || return 7
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
PY
FAIL_CLASS=true
if makevn_capture_test_impact "${tmp}" "${stamp}"; then exit 1; fi
[[ "$(cat "${tmp}/.makevn/test-impact/map.json")" == *'"status": "pending"'* ]]
! find "${tmp}/.makevn/test-impact" -name 'traces.*' | grep -q .
MAKEVN_TEST_IMPACT_CAPTURE=false
makevn_capture_test_impact "${tmp}" "${stamp}"
printf 'Test impact shell capture and failure invalidation passed\n'
