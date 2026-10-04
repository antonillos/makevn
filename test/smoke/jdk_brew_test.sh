#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
export HOME="${tmp}/home" ASDF_DATA_DIR="${tmp}/asdf" JAVA_HOME=""
export MAKEVN_JDK_CANDIDATE_BASES="${tmp}/candidates"
mkdir -p "${tmp}/tools" "${tmp}/repo/.makevn"
manager="${ROOT}/libexec/makevn/jdk/manager.sh"
# High fixture versions isolate this test from any JDKs installed on the host.
for version in 127 128-ea 121; do
  home="${tmp}/brew/openjdk-${version}/libexec/openjdk.jdk/Contents/Home"
  mkdir -p "${home}/bin"
  printf '#!/bin/sh\necho '\''openjdk version "%s"'\'' >&2\n' "${version}" > "${home}/bin/java"
  chmod +x "${home}/bin/java"
done
export MAKEVN_TEST_BREW_ROOT="${tmp}/brew"
cat > "${tmp}/tools/brew" <<'BREW'
#!/bin/sh
case "$*" in
  'list --formula') printf 'openjdk\nopenjdk@121\nopenjdk@128\n';;
  '--prefix openjdk') printf '%s/openjdk-127\n' "$MAKEVN_TEST_BREW_ROOT";;
  '--prefix openjdk@121') printf '%s/openjdk-121\n' "$MAKEVN_TEST_BREW_ROOT";;
  '--prefix openjdk@128') printf '%s/openjdk-128-ea\n' "$MAKEVN_TEST_BREW_ROOT";;
  *) exit 1;;
esac
BREW
chmod +x "${tmp}/tools/brew"
export PATH="${tmp}/tools:${PATH}"
expected="${tmp}/brew/openjdk-127/libexec/openjdk.jdk/Contents/Home"
[[ "$(bash "${manager}" list)" == *"${expected}"* ]]
[[ "$(bash "${manager}" list-compatible-homes 125)" == "${expected}" ]]
[[ "$(bash "${manager}" resolve-compatible-version 125)" == "${expected}" ]]
# Directories and Homebrew share filtering, deduplication and nearest-major choice.
mkdir -p "${MAKEVN_JDK_CANDIDATE_BASES}"
export JAVA_HOME="${expected}"
[[ "$(bash "${manager}" list-compatible-homes 125)" == "${expected}" ]]
home="${MAKEVN_JDK_CANDIDATE_BASES}/126"
mkdir -p "${home}/bin"
printf '#!/bin/sh\necho '\''openjdk version "126"'\'' >&2\n' > "${home}/bin/java"
chmod +x "${home}/bin/java"
[[ "$(bash "${manager}" resolve-compatible-version 125)" == "${home}" ]]
# POM-only doctor and build use the same compatible Homebrew selection.
export JAVA_HOME=""
rm -rf "${home}"
printf '<project><properties><java.version>125</java.version></properties></project>\n' > "${tmp}/repo/pom.xml"
output="$(bash "${ROOT}/libexec/makevn/cli.sh" --repo "${tmp}/repo" doctor)"
[[ "${output}" == *"Resolved code JAVA_HOME: ${expected}"* ]]
cat > "${tmp}/repo/mvnw" <<'MVN'
#!/bin/sh
printf '%s\n' "$JAVA_HOME" > selected-java-home
MVN
chmod +x "${tmp}/repo/mvnw"
bash "${ROOT}/libexec/makevn/backend.sh" compile --repo "${tmp}/repo" --compact >"${tmp}/output" 2>&1
[[ "$(cat "${tmp}/repo/selected-java-home")" == "${expected}" ]]
echo 'Homebrew compatible JDK regression tests passed'
