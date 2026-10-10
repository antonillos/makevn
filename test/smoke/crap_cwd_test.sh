#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rc=$?; if [[ ${rc} != 0 ]]; then cat "${tmp}/result" 2>/dev/null || true; fi; rm -rf "${tmp}"' EXIT
repo="${tmp}/checkout"
mkdir -p "${repo}/code/module/src/main/java/example" "${repo}/code/module/target/site/jacoco" "${repo}/.makevn" "${repo}/jdk/bin" "${tmp}/server"
printf '<project/>\n' > "${repo}/code/pom.xml"
printf '<report><package name="example"><class name="example/Owner"/></package></report>' > "${repo}/code/module/target/site/jacoco/jacoco.xml"
printf '%s\n' 'package example;' 'class Owner {' 'void risk() {' 'int x = 1;' '}' '}' > "${repo}/code/module/src/main/java/example/Owner.java"
touch "${repo}/analyzer.jar"
cat > "${repo}/.makevn/config" <<EOF
MAKEVN_CODE_JAVA_HOME="${repo}/jdk"
MAKEVN_CRAP4JAVA_JAR="${repo}/analyzer.jar"
EOF
cat > "${repo}/jdk/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -version ]]; then printf 'openjdk version "21.0.1"\n' >&2; exit 0; fi
python3 - "$@" <<'PY'
import json, os, sys
entries = [{'file': os.path.relpath(p), 'class': 'example.Owner', 'method': 'risk', 'line': 3, 'end_line': 5, 'complexity': 1, 'coverage_percent': 100, 'crap': 1} for p in sys.argv if p.endswith('.java')]
print(json.dumps({'entries': entries}))
PY
EOF
chmod +x "${repo}/jdk/bin/java"
git init -q "${repo}"
git -C "${repo}" add code/pom.xml code/module/src
git -C "${repo}" -c user.name=Test -c user.email=test@example.com commit -qm base
sed -i.bak 's/int x = 1/int x = 2/' "${repo}/code/module/src/main/java/example/Owner.java"
rm "${repo}/code/module/src/main/java/example/Owner.java.bak"
(cd "${tmp}/server"; CI=1 MAKEVN_AGENT_OUTPUT=1 "${ROOT}/bin/makevn" --repo "${repo}" --compact crap-changes --base HEAD) > "${tmp}/result" 2>&1
python3 - "${repo}/.makevn/reports/crap-changes/report.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
assert len(report['entries']) == 1
assert report['entries'][0]['file'] == 'code/module/src/main/java/example/Owner.java'
PY
printf 'CRAP external working directory regression passed\n'
