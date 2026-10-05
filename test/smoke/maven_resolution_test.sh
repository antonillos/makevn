#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
export HOME="${tmp}/home" ASDF_DATA_DIR="${tmp}/asdf"
repo="${tmp}/repo"
mkdir -p "${repo}/code" "${repo}/e2e/karate"
for pin in ivm-maven/3.9.4 maven/3.9.9; do
  mkdir -p "${ASDF_DATA_DIR}/installs/${pin}/bin"
  printf '#!/usr/bin/env bash\necho pinned-maven\n' > "${ASDF_DATA_DIR}/installs/${pin}/bin/mvn"
  chmod +x "${ASDF_DATA_DIR}/installs/${pin}/bin/mvn"
done
printf 'ivm-maven 3.9.4\n' > "${repo}/.tool-versions"
printf 'java openjdk-21\n' > "${repo}/code/.tool-versions"
expected="${ASDF_DATA_DIR}/installs/ivm-maven/3.9.4/bin/mvn"
[[ "$(makevn_maven_executable "${repo}" "${repo}/code")" == "${expected}" ]]
printf '#!/usr/bin/env bash\nexit 99\n' > "${repo}/mvnw"
chmod +x "${repo}/mvnw"
printf 'maven 3.9.9' > "${repo}/code/.tool-versions"
[[ "$(makevn_maven_executable "${repo}" "${repo}/code")" == "${ASDF_DATA_DIR}/installs/maven/3.9.9/bin/mvn" ]]
printf 'ivm-maven 3.9.4\n' > "${repo}/e2e/karate/.tool-versions"
[[ "$(makevn_maven_executable "${repo}" "${repo}/e2e/karate" karate)" == "${expected}" ]]
mkdir -p "${repo}/.makevn"
printf 'maven 3.9.9\n' > "${tmp}/custom-tools"
printf 'MAKEVN_CODE_TOOL_VERSIONS="%s"\n' "${tmp}/custom-tools" > "${repo}/.makevn/config"
[[ "$(makevn_maven_executable "${repo}" "${repo}/code")" == "${ASDF_DATA_DIR}/installs/maven/3.9.9/bin/mvn" ]]
rm "${repo}/.makevn/config"
printf 'ivm-maven 0.0.0\n' > "${repo}/code/.tool-versions"
if output="$(makevn_maven_executable "${repo}" "${repo}/code" 2>&1)"; then
  echo 'missing pin unexpectedly resolved' >&2; exit 1
fi
[[ "${output}" == *'0.0.0'* && "${output}" == *'not installed'* ]]
printf 'maven ../../escape\n' > "${repo}/code/.tool-versions"
if (makevn_maven_executable "${repo}" "${repo}/code") 2>/dev/null; then exit 1; fi
rm "${repo}/code/.tool-versions" "${repo}/.tool-versions"
[[ "$(makevn_maven_executable "${repo}" "${repo}/code")" == "${repo}/mvnw" ]]
rm "${repo}/mvnw"
[[ "$(makevn_maven_executable "${repo}" "${repo}/code")" == mvn ]]
mkdir -p "${HOME}/.asdf/installs/ivm-maven/3.9.4/bin"
cp "${expected}" "${HOME}/.asdf/installs/ivm-maven/3.9.4/bin/mvn"
unset ASDF_DATA_DIR
printf 'ivm-maven 3.9.4\n' > "${repo}/.tool-versions"
[[ "$(makevn_maven_executable "${repo}" "${repo}/code")" == "${HOME}/.asdf/installs/ivm-maven/3.9.4/bin/mvn" ]]
# Public command integration: a conflicting wrapper/PATH cannot override the pin.
mkdir -p "${tmp}/jdk/bin" "${tmp}/path"
printf '#!/usr/bin/env bash\necho '\''openjdk version "21.0.10"'\'' >&2\n' > "${tmp}/jdk/bin/java"
chmod +x "${tmp}/jdk/bin/java"
printf '<project><modelVersion>4.0.0</modelVersion><groupId>test</groupId><artifactId>pin</artifactId><version>1</version></project>\n' > "${repo}/code/pom.xml"
printf '<project/>\n' > "${repo}/e2e/karate/pom.xml"
printf 'MAKEVN_CODE_JAVA_HOME="%s"\n' "${tmp}/jdk" > "${repo}/.makevn/config"
printf '#!/usr/bin/env bash\nexit 99\n' > "${tmp}/path/mvn"
chmod +x "${tmp}/path/mvn"
export PATH="${tmp}/path:${PATH}"
output="$("${ROOT_DIR}/bin/makevn" --repo "${repo}" doctor --compact)"
[[ "${output}" == *supported* ]]
"${ROOT_DIR}/bin/makevn" --repo "${repo}" init >/dev/null
output="$("${ROOT_DIR}/bin/makevn" --repo "${repo}" doctor)"
[[ "${output}" == *"Resolved code Maven: ${HOME}/.asdf/installs/ivm-maven/3.9.4/bin/mvn"* ]]
output="$("${ROOT_DIR}/bin/makevn" --repo "${repo}" validate)"
[[ "${output}" == *'[ok]'* ]]
printf 'ivm-maven 0.0.0\n' > "${repo}/code/.tool-versions"
if output="$("${ROOT_DIR}/bin/makevn" --repo "${repo}" validate 2>&1)"; then exit 1; fi
[[ "${output}" == *'0.0.0'* && "${output}" == *'not installed'* ]]
echo 'Maven resolution tests passed'
