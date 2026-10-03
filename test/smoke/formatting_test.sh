#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
source "${ROOT}/libexec/makevn/common.sh"
source "${ROOT}/libexec/makevn/commands/maven.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
for error in   'AJF validate: AJF Formatter plugin failed.'   "File '/repo/Test.java' has not been previously formatted. Please format file."   'AJF verify: AJF sortPom plugin failed.'   'The file /repo/module/pom.xml is not sorted'   'spotless check violations'; do
  printf '%s\n' "${error}" > "${tmp}/log"
  makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
  grep -Fxq '  makevn format --apply' "${tmp}/hint"
  grep -Fq 'MCP suggestion: makevn_format with apply: true.' "${tmp}/hint"
  grep -Fq 'Do not add formatter skip flags' "${tmp}/hint"
  ! grep -Fq -- '--file' "${tmp}/hint"
done
printf '%s\n' 'Tests run: 1, Failures: 1' > "${tmp}/log"
makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
[[ ! -s "${tmp}/hint" ]]
makevn_hint_format_failure "${tmp}" "${tmp}/absent" 2>"${tmp}/hint"
[[ ! -s "${tmp}/hint" ]]
if (cmd_format "${tmp}" --file Test.java) 2>"${tmp}/error"; then exit 1; fi
grep -Fq 'Unknown format option: --file' "${tmp}/error"
echo 'formatting detection tests passed'
