#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common.sh"
tmp="$(mktemp -d)"
tmp="$(CDPATH= cd -P -- "${tmp}" && pwd -P)"
trap 'rm -rf "${tmp}"' EXIT
export HOME="${tmp}/home" ASDF_DATA_DIR="${tmp}/custom-asdf"
original_path="${PATH}"
repo="${tmp}/repo"
mkdir -p "${repo}/code" "${repo}/e2e/karate" "${ASDF_DATA_DIR}/shims" "${tmp}/system/bin" "${tmp}/empty"
printf '#!/usr/bin/env bash\nexit 99\n' > "${ASDF_DATA_DIR}/shims/mvn"
printf '#!/usr/bin/env bash\necho system-maven\n' > "${tmp}/system/bin/mvn"
chmod +x "${ASDF_DATA_DIR}/shims/mvn" "${tmp}/system/bin/mvn"
cp "${ASDF_DATA_DIR}/shims/mvn" "${repo}/mvnw"
ln -s "${ASDF_DATA_DIR}/shims" "${tmp}/shim-alias"
export PATH="${tmp}/shim-alias:${ASDF_DATA_DIR}/shims:${tmp}/missing:${tmp}/empty:${tmp}/system/bin:${original_path}"
for tool in maven ivm-maven; do
  printf '%s system\n' "${tool}" > "${repo}/code/.tool-versions"
  printf '%s system\n' "${tool}" > "${repo}/e2e/karate/.tool-versions"
  [[ "$(makevn_maven_executable "${repo}" "${repo}/code")" == "${tmp}/system/bin/mvn" ]]
  [[ "$(makevn_maven_executable "${repo}" "${repo}/e2e/karate" karate)" == "${tmp}/system/bin/mvn" ]]
done
# A shim-only PATH must fail even if a wrapper is available.
mkdir -p "${tmp}/tools"
ln -s "$(command -v awk)" "${tmp}/tools/awk"
if output="$(PATH="${ASDF_DATA_DIR}/shims:${tmp}/tools" makevn_maven_executable "${repo}" "${repo}/code" 2>&1)"; then
  echo 'shim-only system pin unexpectedly resolved' >&2; exit 1
fi
# Test the system resolver directly with a constrained PATH.
if output="$(PATH="${ASDF_DATA_DIR}/shims" makevn_system_maven_executable "${repo}/code/.tool-versions" 2>&1)"; then exit 1; fi
[[ "${output}" == *'no non-asdf system mvn'* ]]
export PATH="${original_path}"
mkdir -p "${HOME}/.asdf/shims"
cp "${ASDF_DATA_DIR}/shims/mvn" "${HOME}/.asdf/shims/mvn"
unset ASDF_DATA_DIR
export PATH="${HOME}/.asdf/shims:${tmp}/system/bin:${original_path}"
[[ "$(makevn_maven_executable "${repo}" "${repo}/code")" == "${tmp}/system/bin/mvn" ]]
# Public doctor/validate preserve system pins independently of the root pin.
mkdir -p "${tmp}/jdk/bin" "${repo}/.makevn"
printf '#!/usr/bin/env bash\necho '\''openjdk version "21.0.10"'\'' >&2\n' > "${tmp}/jdk/bin/java"
chmod +x "${tmp}/jdk/bin/java"
printf '<project/>\n' > "${repo}/code/pom.xml"
printf '<project/>\n' > "${repo}/e2e/karate/pom.xml"
printf 'ivm-maven 0.0.0\n' > "${repo}/.tool-versions"
printf 'MAKEVN_CODE_JAVA_HOME="%s"\n' "${tmp}/jdk" > "${repo}/.makevn/config"
"${ROOT_DIR}/bin/makevn" --repo "${repo}" doctor --compact >/dev/null
"${ROOT_DIR}/bin/makevn" --repo "${repo}" init >/dev/null
output="$("${ROOT_DIR}/bin/makevn" --repo "${repo}" doctor)"
[[ "${output}" == *"Resolved code Maven: ${tmp}/system/bin/mvn"* ]]
[[ "${output}" == *"Resolved Karate Maven: ${tmp}/system/bin/mvn"* ]]
output="$("${ROOT_DIR}/bin/makevn" --repo "${repo}" validate)"
[[ "${output}" == *'[ok]'* ]]
grep -Fq system-maven "${repo}/.makevn/logs/validate.log"
echo 'Maven system pin tests passed'
