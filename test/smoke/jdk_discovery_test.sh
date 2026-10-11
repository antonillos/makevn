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
printf 'ivm-java openjdk-21.0.10' > "${TMP}/repo/code/.tool-versions"
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
# Windows JDKs discovered under WSL may expose only java.exe.
for version in 21.0.10 '21.0.4+tzdata2024b'; do
  home="${ASDF_DATA_DIR}/installs/ivm-java/openjdk-${version}"
  mv "${home}/bin/java" "${home}/bin/java.exe"
done
output="$("${ROOT_DIR}/bin/makevn" --repo "${TMP}/repo" jdk current)"
[[ "${output}" == *'openjdk version "21.0.10"'* ]]
[[ "${output}" == *'openjdk version "21.0.4"'* ]]
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
# An unterminated final entry must beat another installed same-major JDK.
cp -R "${HOME}/.asdf/installs/java/openjdk-21.0.10" "${HOME}/.asdf/installs/java/aaa-21.0.10"
printf 'java openjdk-21.0.10'  > "${TMP}/repo/code/.tool-versions"
actual="$(bash "${manager}" resolve-tool-versions "${TMP}/repo/code/.tool-versions")"
[[ "${actual}" == "${HOME}/.asdf/installs/java/openjdk-21.0.10" ]]
printf 'JDK discovery regression tests passed\n' 

# Automatic numeric resolution must not mistake EA/project builds for GA.
mkdir -p "${TMP}/tools"
printf '#!/bin/sh\nexit 1\n' > "${TMP}/tools/brew"
chmod +x "${TMP}/tools/brew"
export PATH="${TMP}/tools:${PATH}"
export MAKEVN_JDK_CANDIDATE_BASES="${TMP}/candidates"
for version in 25-loom 25-ea 25-internal 26-ea; do
  home="${MAKEVN_JDK_CANDIDATE_BASES}/${version}"
  mkdir -p "${home}/bin"
  printf '#!/bin/sh\necho '\''openjdk version "%s"'\'' >&2\n' "${version}" > "${home}/bin/java"
  chmod +x "${home}/bin/java"
done
export JAVA_HOME="${MAKEVN_JDK_CANDIDATE_BASES}/25-loom"
if bash "${manager}" resolve-version 25 >"${TMP}/result"; then
  echo 'numeric discovery selected an experimental JDK'; exit 1
fi
[[ ! -s "${TMP}/result" ]]
[[ -z "$(bash "${manager}" list-compatible-homes 25)" ]]
if bash "${manager}" resolve-compatible-version 25; then
  echo 'compatible fallback selected an experimental JDK'; exit 1
fi
# Inventory still exposes experimental installations for deliberate selection.
[[ "$(bash "${manager}" list)" == *"${JAVA_HOME}"* ]]
for version in 25.0.1 26.0.1; do
  home="${MAKEVN_JDK_CANDIDATE_BASES}/${version}"
  mkdir -p "${home}/bin"
  printf '#!/bin/sh\necho '\''openjdk version "%s"'\'' >&2\n' "${version}" > "${home}/bin/java"
  chmod +x "${home}/bin/java"
done
[[ "$(bash "${manager}" resolve-version 25)" == "${MAKEVN_JDK_CANDIDATE_BASES}/25.0.1" ]]
[[ "$(bash "${manager}" resolve-compatible-version 25)" == "${MAKEVN_JDK_CANDIDATE_BASES}/25.0.1" ]]
rm -rf "${MAKEVN_JDK_CANDIDATE_BASES}/25.0.1"
[[ "$(bash "${manager}" resolve-compatible-version 25)" == "${MAKEVN_JDK_CANDIDATE_BASES}/26.0.1" ]]
# Explicit paths and repository-pinned asdf installations remain authoritative.
[[ "$(bash "${manager}" resolve-version "${JAVA_HOME}")" == "${JAVA_HOME}" ]]
mkdir -p "${HOME}/.asdf/installs/java/openjdk-25-loom"
cp -R "${JAVA_HOME}/bin" "${HOME}/.asdf/installs/java/openjdk-25-loom/"
printf 'java openjdk-25-loom\n' > "${TMP}/repo/code/.tool-versions"
# Use a numeric-suffix pin understood by the existing tool-versions parser.
mv "${HOME}/.asdf/installs/java/openjdk-25-loom" "${HOME}/.asdf/installs/java/loom-25"
printf 'java loom-25\n' > "${TMP}/repo/code/.tool-versions"
[[ "$(bash "${manager}" resolve-tool-versions "${TMP}/repo/code/.tool-versions")" == "${HOME}/.asdf/installs/java/loom-25" ]]
printf 'MAKEVN_CODE_JAVA_HOME="%s"\n' "${JAVA_HOME}" > "${TMP}/repo/.makevn/config"
output="$("${ROOT_DIR}/bin/makevn" --repo "${TMP}/repo" jdk current)"
[[ "${output}" == *"Effective code JDK: ${JAVA_HOME}"* ]]
printf 'Stable JDK selection regression tests passed\n'
# POM-only projects get actionable doctor guidance instead of a Loom fallback.
rm -rf "${MAKEVN_JDK_CANDIDATE_BASES}/26.0.1"
rm -f "${TMP}/repo/code/.tool-versions" "${TMP}/repo/.makevn/config"
printf '<project><properties><java.version>25</java.version></properties></project>\n' > "${TMP}/repo/pom.xml"
rm -f "${TMP}/repo/code/pom.xml"
output="$(bash "${ROOT_DIR}/libexec/makevn/cli.sh" --repo "${TMP}/repo" doctor)"
[[ "${output}" == *'Resolved code JAVA_HOME: unresolved'* ]]
[[ "${output}" == *'No stable JDK 25+ detected'* ]]
[[ "${output}" == *'Automatic selection excludes EA/internal/project builds'* ]]
printf 'Stable JDK doctor regression tests passed\n'
# A build must stop before Maven when only experimental candidates exist.
cat > "${TMP}/repo/mvnw" <<'MVN'
#!/bin/sh
touch maven-invoked
MVN
chmod +x "${TMP}/repo/mvnw"
if bash "${ROOT_DIR}/libexec/makevn/backend.sh" compile --repo "${TMP}/repo" --compact >"${TMP}/compile-output" 2>&1; then
  echo 'compile unexpectedly accepted an experimental JDK'; exit 1
fi
grep -Fq 'Could not resolve code JDK' "${TMP}/compile-output"
[[ ! -e "${TMP}/repo/maven-invoked" ]]
# An explicit experimental override still reaches Maven.
printf 'MAKEVN_CODE_JAVA_HOME="%s"\n' "${JAVA_HOME}" > "${TMP}/repo/.makevn/config"
bash "${ROOT_DIR}/libexec/makevn/backend.sh" compile --repo "${TMP}/repo" --compact >"${TMP}/compile-output" 2>&1
[[ -f "${TMP}/repo/maven-invoked" ]]
for version in '1.8.0_402' '99.0.1+8-LTS'; do
  home="${MAKEVN_JDK_CANDIDATE_BASES}/${version}"
  mkdir -p "${home}/bin"
  printf '#!/bin/sh\necho '\''openjdk version "%s"'\'' >&2\n' "${version}" > "${home}/bin/java"
  chmod +x "${home}/bin/java"
done
[[ "$(bash "${manager}" resolve-version 8)" == "${MAKEVN_JDK_CANDIDATE_BASES}/1.8.0_402" ]]
[[ "$(bash "${manager}" resolve-version 99)" == "${MAKEVN_JDK_CANDIDATE_BASES}/99.0.1+8-LTS" ]]
printf 'Stable JDK build and version-format regression tests passed\n'
