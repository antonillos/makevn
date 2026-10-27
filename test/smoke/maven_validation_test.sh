#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
repo="${fixture}/repo"
aggregate="${repo}/aidev/work/preflight/code"
mkdir -p "${aggregate}/apifirst-compiler-event" "${repo}/.makevn" "${fixture}/jdk/bin" "${fixture}/path"
cat > "${aggregate}/pom.xml" <<'XML'
<project><modelVersion>4.0.0</modelVersion><groupId>test</groupId><artifactId>compiler</artifactId><version>1</version>
<modules><module>apifirst-compiler-event</module></modules>
<build><plugins><plugin><artifactId>maven-enforcer-plugin</artifactId><executions>
<execution><goals><goal>enforce</goal></goals><configuration><rules>
<requireMavenVersion><version>[3.9.14,3.10.0)</version></requireMavenVersion>
</rules></configuration></execution></executions></plugin></plugins></build></project>
XML
printf '<project><parent><relativePath>../pom.xml</relativePath></parent></project>\n' > "${aggregate}/apifirst-compiler-event/pom.xml"
printf '#!/bin/sh\necho '\''openjdk version "25.0.3"'\'' >&2\n' > "${fixture}/jdk/bin/java"
chmod +x "${fixture}/jdk/bin/java"
printf 'MAKEVN_CODE_JAVA_HOME="%s"\n' "${fixture}/jdk" > "${repo}/.makevn/config"
cat > "${fixture}/path/mvn" <<'SH'
#!/bin/sh
if [ "$1" = --version ]; then
  printf 'Apache Maven %s\n' "$TEST_MAVEN_VERSION"
else
  printf '%s\n' executed > "$TEST_MAVEN_MARKER"
fi
SH
chmod +x "${fixture}/path/mvn"
export PATH="${fixture}/path:${PATH}" TEST_MAVEN_VERSION=3.9.9 TEST_MAVEN_MARKER="${fixture}/executed"
[[ "$(makevn_detect_maven_base_path_fresh "${repo}")" == "${aggregate}" ]]
output="$("${ROOT_DIR}/bin/makevn" --repo "${repo}" doctor --compact)"
[[ "${output}" == *'does not satisfy requireMavenVersion: [3.9.14,3.10.0)'* ]]
[[ ! -f "${TEST_MAVEN_MARKER}" ]]
"${ROOT_DIR}/bin/makevn" --repo "${repo}" init >/dev/null
if output="$("${ROOT_DIR}/bin/makevn" --repo "${repo}" validate 2>&1)"; then
  printf '%s\n' 'Incompatible Maven unexpectedly executed' >&2
  exit 1
fi
[[ "${output}" == *'does not satisfy requireMavenVersion'* ]]
[[ ! -f "${TEST_MAVEN_MARKER}" ]]
export TEST_MAVEN_VERSION=3.9.14
output="$("${ROOT_DIR}/bin/makevn" --repo "${repo}" doctor --compact)"
[[ "${output}" == *'3.9.14 (installed)'* && "${output}" == *'compatible'* ]]
"${ROOT_DIR}/bin/makevn" --repo "${repo}" validate >/dev/null
[[ -f "${TEST_MAVEN_MARKER}" ]]
# A pin next to the nested aggregator is visible after project discovery.
export ASDF_DATA_DIR="${fixture}/asdf"
mkdir -p "${ASDF_DATA_DIR}/installs/maven/3.9.14/bin"
cp "${fixture}/path/mvn" "${ASDF_DATA_DIR}/installs/maven/3.9.14/bin/mvn"
printf 'maven 3.9.14\n' > "${aggregate}/.tool-versions"
[[ "$(makevn_maven_executable "${repo}" "${aggregate}")" == "${ASDF_DATA_DIR}/installs/maven/3.9.14/bin/mvn" ]]
# Independent projects must not be silently chosen by alphabetical order.
mkdir -p "${repo}/another"
printf '<project/>\n' > "${repo}/another/pom.xml"
if output="$("${ROOT_DIR}/bin/makevn" --repo "${repo}" doctor --compact 2>&1)"; then exit 1; fi
[[ "${output}" == *'Ambiguous Maven projects'* ]]
printf '%s\n' 'Maven validation tests passed'
