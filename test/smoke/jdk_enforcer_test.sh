#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/repo/.makevn" "${tmp}/tools"
export HOME="${tmp}/home" ASDF_DATA_DIR="${tmp}/asdf" JAVA_HOME=""
export MAKEVN_JDK_CANDIDATE_BASES="${tmp}/jdks"
export MAKEVN_JDK_MAVEN_BASE_PATH="${tmp}/repo"
printf '#!/bin/sh\nexit 1\n' > "${tmp}/tools/brew"
chmod +x "${tmp}/tools/brew"
export PATH="${tmp}/tools:${PATH}"
manager="${ROOT}/libexec/makevn/jdk/manager.sh"
mkdir -p "${tmp}/jdks/127/bin"
printf '#!/bin/sh\necho '\''openjdk version "127"'\'' >&2\n' > "${tmp}/jdks/127/bin/java"
chmod +x "${tmp}/jdks/127/bin/java"
cat > "${tmp}/repo/pom.xml" <<'POM'
<project><properties><java.version>125</java.version><jdk.range>[125,126)</jdk.range></properties>
<build><plugins><plugin><artifactId>maven-enforcer-plugin</artifactId><executions><execution>
<goals><goal>enforce</goal></goals><configuration><rules><requireJavaVersion>
<version>${jdk.range}</version></requireJavaVersion></rules></configuration>
</execution></executions></plugin></plugins></build></project>
POM
[[ -z "$(bash "${manager}" list-compatible-homes 125)" ]]
if bash "${manager}" resolve-compatible-version 125; then
  echo 'Enforcer upper bound ignored'; exit 1
fi
output="$(bash "${ROOT}/libexec/makevn/cli.sh" --repo "${tmp}/repo" doctor)"
[[ "${output}" == *'Resolved code JAVA_HOME: unresolved'* ]]
[[ "${output}" == *'Maven Enforcer requireJavaVersion: [125,126)'* ]]
cat > "${tmp}/repo/mvnw" <<'MVN'
#!/bin/sh
printf '%s\n' "$JAVA_HOME" > maven-java-home
MVN
chmod +x "${tmp}/repo/mvnw"
if bash "${ROOT}/libexec/makevn/backend.sh" compile --repo "${tmp}/repo" --compact >"${tmp}/output" 2>&1; then
  echo 'Maven started with a forbidden JDK'; exit 1
fi
[[ ! -e "${tmp}/repo/maven-java-home" ]]
mkdir -p "${tmp}/jdks/125.0.2/bin"
printf '#!/bin/sh\necho '\''openjdk version "125.0.2"'\'' >&2\n' > "${tmp}/jdks/125.0.2/bin/java"
chmod +x "${tmp}/jdks/125.0.2/bin/java"
expected="${tmp}/jdks/125.0.2"
[[ "$(bash "${manager}" resolve-version 125)" == "${expected}" ]]
[[ "$(bash "${manager}" resolve-compatible-version 125)" == "${expected}" ]]
bash "${ROOT}/libexec/makevn/backend.sh" compile --repo "${tmp}/repo" --compact >"${tmp}/output" 2>&1
[[ "$(cat "${tmp}/repo/maven-java-home")" == "${expected}" ]]
# Exact-version discovery must respect patch-level constraints too.
sed 's/\[125,126)/[125.0.3,126)/' "${tmp}/repo/pom.xml" > "${tmp}/new-pom"
mv "${tmp}/new-pom" "${tmp}/repo/pom.xml"
if bash "${manager}" resolve-version 125; then
  echo 'exact discovery ignored Enforcer patch bound'; exit 1
fi
# Explicit config remains deliberate; Maven still enforces it at execution.
printf 'MAKEVN_CODE_JAVA_HOME="%s/jdks/127"\n' "${tmp}" > "${tmp}/repo/.makevn/config"
bash "${ROOT}/libexec/makevn/backend.sh" compile --repo "${tmp}/repo" --compact >"${tmp}/output" 2>&1
[[ "$(cat "${tmp}/repo/maven-java-home")" == "${tmp}/jdks/127" ]]
# A repository pin is authoritative even when it conflicts with Enforcer.
# Automatic discovery must still reject the same forbidden major.
sed 's/\[125.0.3,126)/[126,)/' "${tmp}/repo/pom.xml" > "${tmp}/new-pom"
mv "${tmp}/new-pom" "${tmp}/repo/pom.xml"
rm -f "${tmp}/repo/.makevn/config"
pin="${ASDF_DATA_DIR}/installs/java/company-125"
mkdir -p "${pin}"
cp -R "${expected}/bin" "${pin}/"
printf 'java company-125\n' > "${tmp}/repo/.tool-versions"
[[ "$(bash "${manager}" resolve-tool-versions "${tmp}/repo/.tool-versions")" == "${pin}" ]]
[[ "$(bash "${manager}" resolve-compatible-version 125)" == "${tmp}/jdks/127" ]]
bash "${ROOT}/libexec/makevn/backend.sh" compile --repo "${tmp}/repo" --compact >"${tmp}/output" 2>&1
[[ "$(cat "${tmp}/repo/maven-java-home")" == "${pin}" ]]
echo 'Enforcer-aware JDK regression tests passed'
# Rules in unconditional reactor modules constrain the whole Maven invocation.
rm -f "${tmp}/repo/.makevn/config" "${tmp}/repo/.tool-versions"
cat > "${tmp}/repo/pom.xml" <<'POM'
<project><properties><java.version>125</java.version></properties>
<modules><module>feature</module></modules></project>
POM
mkdir -p "${tmp}/repo/feature"
cat > "${tmp}/repo/feature/pom.xml" <<'POM'
<project><build><plugins><plugin><artifactId>maven-enforcer-plugin</artifactId>
<executions><execution><goals><goal>enforce</goal></goals><configuration><rules>
<requireJavaVersion><version>[127,128)</version></requireJavaVersion>
</rules></configuration></execution></executions></plugin></plugins></build></project>
POM
if bash "${manager}" resolve-version 125; then
  echo 'exact discovery ignored a reactor module rule'; exit 1
fi
[[ "$(bash "${manager}" resolve-compatible-version 125)" == "${tmp}/jdks/127" ]]
output="$(bash "${ROOT}/libexec/makevn/cli.sh" --repo "${tmp}/repo" doctor)"
[[ "${output}" == *"Resolved code JAVA_HOME: ${tmp}/jdks/127"* ]]
bash "${ROOT}/libexec/makevn/backend.sh" compile --repo "${tmp}/repo" --compact >"${tmp}/output" 2>&1
[[ "$(cat "${tmp}/repo/maven-java-home")" == "${tmp}/jdks/127" ]]
echo 'Reactor Enforcer JDK regression tests passed'
