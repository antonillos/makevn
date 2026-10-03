#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
source "${ROOT}/libexec/makevn/common.sh"
source "${ROOT}/libexec/makevn/commands/maven.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
for error in   'AJF validate: AJF Formatter plugin failed.'   'AJF verify: AJF sortPom plugin failed.'   '[ERROR] The following files had format violations:'   'Failed to execute goal com.diffplug.spotless:spotless-maven-plugin:2.43.0:check'   'Failed to execute goal com.inditex.libamfmt:amiga-javaformat-maven-plugin:3.7.0:validate'   'Failed to execute goal net.revelc.code.formatter:formatter-maven-plugin:2.24.0:validate' ; do
  printf '%s\n' "${error}" > "${tmp}/log"
  makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
  grep -Fxq '  makevn format --apply' "${tmp}/hint"
  grep -Fq 'MCP suggestion: makevn_format with apply: true.' "${tmp}/hint"
  grep -Fq 'without --fast' "${tmp}/hint"
  grep -Fq 'Do not add formatter skip flags' "${tmp}/hint"
  ! grep -Fq -- '--file' "${tmp}/hint"
done
printf '%s\n' '[INFO] --- spotless-maven-plugin:2.43.0:check (default) @ fixture ---' 'Tests run: 1, Failures: 1' > "${tmp}/log"
makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
[[ ! -s "${tmp}/hint" ]]
for diagnostic in 'items are not sorted' 'date format parsing failed' "File 'Test.java' has not been previously formatted" 'spotless check completed'; do
  printf '%s\n' "${diagnostic}" 'Tests run: 1, Failures: 1' > "${tmp}/log"
  makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
  [[ ! -s "${tmp}/hint" ]]
done
makevn_hint_format_failure "${tmp}" "${tmp}/absent" 2>"${tmp}/hint"
[[ ! -s "${tmp}/hint" ]]
if (cmd_format "${tmp}" --file Test.java) 2>"${tmp}/error"; then exit 1; fi
grep -Fq 'Unknown format option: --file' "${tmp}/error"

mkdir -p "${tmp}/.makevn"
cat > "${tmp}/pom.xml" <<'POM'
<project><build><plugins><plugin><groupId>com.example</groupId><artifactId>company-format-maven-plugin</artifactId><executions><execution><goals><goal>check</goal></goals></execution></executions></plugin></plugins></build></project>
POM
printf '%s\n' '[ERROR] Failed to execute goal com.example:company-format-maven-plugin:1.0:check' > "${tmp}/log"
makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
grep -Fq 'makevn format --apply' "${tmp}/hint"
printf 'MAKEVN_FORMAT_CHECK_GOAL="com.example:custom-gate:verify-style"\n' > "${tmp}/.makevn/config"
printf '%s\n' '[ERROR] Failed to execute goal com.example:custom-gate:2.0:verify-style' > "${tmp}/log"
makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
grep -Fq 'makevn format --apply' "${tmp}/hint"
printf '%s\n' '[INFO] --- com.example:custom-gate:2.0:verify-style ---' 'Tests run: 1, Failures: 1' > "${tmp}/log"
makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
[[ ! -s "${tmp}/hint" ]]
printf '%s\n' '[ERROR] Failed to execute goal org.other:custom-gate:2.0:verify-style' > "${tmp}/log"
makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
[[ ! -s "${tmp}/hint" ]]
echo 'formatting detection tests passed'
