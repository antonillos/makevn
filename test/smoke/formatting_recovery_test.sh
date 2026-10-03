#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/.makevn" "${tmp}/jdk/bin" "${tmp}/src/test/java"
cat > "${tmp}/pom.xml" <<'POM'
<project><modelVersion>4.0.0</modelVersion><groupId>fixture</groupId><artifactId>format</artifactId><version>1</version><build><plugins><plugin><groupId>com.inditex.libamfmt</groupId><artifactId>amiga-javaformat-maven-plugin</artifactId></plugin></plugins></build></project>
POM
printf 'package fixture;\nclass ExampleIT {}\n' > "${tmp}/src/test/java/ExampleIT.java"
printf 'package fixture;\nclass ExampleTest {}\n' > "${tmp}/src/test/java/ExampleTest.java"
printf '#!/bin/sh\necho java fixture\n' > "${tmp}/jdk/bin/java"
chmod +x "${tmp}/jdk/bin/java"
printf 'MAKEVN_CODE_JAVA_HOME="%s/jdk"\n' "${tmp}" > "${tmp}/.makevn/config"
cat > "${tmp}/mvnw" <<'MVN'
#!/bin/sh
case "$*" in
  *amiga-javaformat-maven-plugin:apply*) echo format-ok; exit 0;;
esac
echo '[ERROR] Failed to execute goal com.inditex.libamfmt:amiga-javaformat-maven-plugin:3.7.0:validate: AJF Formatter plugin failed.'
echo "[ERROR] File '$PWD/src/test/java/ExampleIT.java' has not been previously formatted. Please format file."
exit 7
MVN
chmod +x "${tmp}/mvnw"
for selection in all ExampleIT ExampleTest; do
  args=()
  [[ "${selection}" == all ]] || args=(--name "${selection}")
  set +e
  bash "${ROOT}/libexec/makevn/cli.sh" --repo "${tmp}" --compact test "${args[@]}" >"${tmp}/output" 2>&1
  rc=$?
  set -e
  [[ "${rc}" == 7 ]] || { cat "${tmp}/output"; echo "expected exit 7, got ${rc}"; exit 1; }
  grep -Fq 'MCP suggestion: makevn_format with apply: true' "${tmp}/output" || { cat "${tmp}/output"; exit 1; }
  grep -Fq 'Do not add formatter skip flags' "${tmp}/output"
done
# The separate whole-project AMIGA command works; --file is not supported.
bash "${ROOT}/libexec/makevn/cli.sh" --repo "${tmp}" --compact format --apply >"${tmp}/output" 2>&1
grep -Fq '[ok]' "${tmp}/output"

if [[ -x "${ROOT}/target/release/makevn-mcp" ]]; then
  python3 - "${ROOT}/target/release/makevn-mcp" "${tmp}" <<'MCP'
import json, os, subprocess, sys
binary, repo = sys.argv[1:]
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
     "params": {"name": "format", "arguments": {"repo": repo, "apply": True}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
     "params": {"name": "test", "arguments": {"repo": repo, "name": "ExampleIT"}}},
]
result = subprocess.run([binary], input="".join(json.dumps(r) + "\n" for r in requests),
                        text=True, capture_output=True, timeout=30, check=True,
                        env={**os.environ, "MAKEVN_INSTALL_ROOT": os.path.dirname(os.path.dirname(os.path.dirname(binary)))})
responses = {r["id"]: r for r in map(json.loads, result.stdout.splitlines()) if "id" in r}
tools = responses[1]["result"]["tools"]
formatter = next(t for t in tools if t["name"] == "format")
assert "file" in formatter["inputSchema"]["properties"]
assert not responses[2]["result"].get("isError", False), responses[2]
text = "\n".join(c.get("text", "") for c in responses[3]["result"]["content"])
assert "MCP suggestion: makevn_format with apply: true" in text, text
assert "exit code 7" in text, text
MCP
fi
echo 'formatting recovery integration tests passed'

