#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
export HOME="${TMP}/home" ASDF_DATA_DIR="${TMP}/asdf" JAVA_HOME="${TMP}/jdk26"
unset MAKEVN_JDK_CANDIDATE_BASES
for version in 21.0.10 '21.0.4+tzdata2024b'; do
  home="${ASDF_DATA_DIR}/installs/ivm-java/openjdk-${version}"
  mkdir -p "${home}/bin"
  printf '#!/usr/bin/env bash\nprintf '\''openjdk version "%s"\\n'\'' >&2\n' "${version%%+*}" > "${home}/bin/java"
  chmod +x "${home}/bin/java"
done
mkdir -p "${JAVA_HOME}/bin" "${TMP}/repo/code" "${TMP}/repo/e2e/karate"
printf '#!/usr/bin/env bash\necho '\''openjdk version "26.0.2.1"'\'' >&2\n' > "${JAVA_HOME}/bin/java"
chmod +x "${JAVA_HOME}/bin/java"
printf '<project/>\n' > "${TMP}/repo/code/pom.xml"
printf 'ivm-java openjdk-21.0.10\n' > "${TMP}/repo/code/.tool-versions"
printf 'ivm-java openjdk-21.0.4+tzdata2024b\n' > "${TMP}/repo/e2e/karate/.tool-versions"
manager="${ROOT_DIR}/libexec/makevn/jdk/manager.sh"
for context in code e2e/karate; do
  version="$(awk '{print $2}' "${TMP}/repo/${context}/.tool-versions")"
  actual="$(bash "${manager}" resolve-tool-versions "${TMP}/repo/${context}/.tool-versions")"
  [[ "${actual}" == "${ASDF_DATA_DIR}/installs/ivm-java/${version}" ]]
done
output="$(bash "${manager}" list)"
[[ "${output}" == *"${ASDF_DATA_DIR}/installs/ivm-java/openjdk-21.0.10"* ]]
output="$("${ROOT_DIR}/bin/makevn" --repo "${TMP}/repo" jdk current)"
[[ "${output}" == *"Effective code JDK: ${ASDF_DATA_DIR}/installs/ivm-java/openjdk-21.0.10"* ]]
[[ "${output}" == *"Effective karate JDK: ${ASDF_DATA_DIR}/installs/ivm-java/openjdk-21.0.4+tzdata2024b"* ]]
mkdir -p "${TMP}/repo/.makevn"
printf 'MAKEVN_CODE_JAVA_HOME="%s"\nMAKEVN_KARATE_JAVA_HOME="%s"\n' "${JAVA_HOME}" "${JAVA_HOME}" > "${TMP}/repo/.makevn/config"
output="$("${ROOT_DIR}/bin/makevn" --repo "${TMP}/repo" jdk current)"
[[ "${output}" == *"Effective code JDK: ${JAVA_HOME}"* ]]
[[ "${output}" == *"Effective karate JDK: ${JAVA_HOME}"* ]]
# Default asdf root works without ASDF_DATA_DIR too.
mkdir -p "${HOME}"
mv "${ASDF_DATA_DIR}" "${HOME}/.asdf"
unset ASDF_DATA_DIR
actual="$(bash "${manager}" resolve-tool-versions "${TMP}/repo/code/.tool-versions")"
[[ "${actual}" == "${HOME}/.asdf/installs/ivm-java/openjdk-21.0.10" ]]
mkdir -p "${HOME}/.asdf/installs/java"
mv "${HOME}/.asdf/installs/ivm-java/openjdk-21.0.10" "${HOME}/.asdf/installs/java/"
printf 'java openjdk-21.0.10\n' > "${TMP}/repo/code/.tool-versions"
actual="$(bash "${manager}" resolve-tool-versions "${TMP}/repo/code/.tool-versions")"
[[ "${actual}" == "${HOME}/.asdf/installs/java/openjdk-21.0.10" ]]
printf 'JDK discovery regression tests passed\n' 
