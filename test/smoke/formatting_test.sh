#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
source "${ROOT}/libexec/makevn/common.sh"
source "${ROOT}/libexec/makevn/commands/maven.sh"
tmp="$(mktemp -d)"
tmp="$(cd "${tmp}" && pwd -P)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/module/src"
touch "${tmp}/pom.xml" "${tmp}/module/pom.xml" "${tmp}/module/src/A.java"
makevn_run_maven_goal() { printf '%s\n' "$@" > "${tmp}/args"; }
makevn_format_single_file "${tmp}" "${tmp}" spotless:apply module/src/A.java
grep -Fxq -- '-N' "${tmp}/args"
grep -Fxq -- "${tmp}/module/pom.xml" "${tmp}/args"
grep -Fq -- '-DspotlessFiles=^' "${tmp}/args"
if (makevn_format_single_file "${tmp}" "${tmp}" amiga:apply module/pom.xml) 2>"${tmp}/err"; then exit 1; fi
grep -Fq 'not supported' "${tmp}/err"
if (makevn_format_single_file "${tmp}" "${tmp}" spotless:apply ../missing) 2>"${tmp}/err"; then exit 1; fi
printf '%s\n' '[ERROR] AJF verify: AJF sortPom plugin failed.' '[ERROR] The file /repo/module/pom.xml is not sorted' > "${tmp}/log"
makevn_detect_maven_base_path() { printf '%s\n' "${tmp}"; }
makevn_detect_format_plugin_goal() { printf '%s\n' amiga:apply; }
makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
grep -Fq 'makevn format --apply' "${tmp}/hint"
grep -Fq 'Do not add formatter skip flags' "${tmp}/hint"
printf '%s\n' 'Tests run: 1, Failures: 1' > "${tmp}/log"
makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
[[ ! -s "${tmp}/hint" ]]

# Check and fully qualified goals share the same safe file selector.
makevn_format_single_file "${tmp}" "${tmp}" com.diffplug.spotless:spotless-maven-plugin:check "${tmp}/module/src/A.java"
makevn_detect_format_plugin_goal() { printf '%s\n' spotless:apply; }
printf '%s\n' 'The file /repo/module/pom.xml is not sorted' > "${tmp}/log"
makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
grep -Fq 'makevn format --apply --file /repo/module/pom.xml' "${tmp}/hint"
printf '%s\n' 'spotless check violations' > "${tmp}/log"
makevn_hint_format_failure "${tmp}" "${tmp}/log" 2>"${tmp}/hint"
grep -Fxq '  makevn format --apply' "${tmp}/hint"
makevn_hint_format_failure "${tmp}" "${tmp}/absent" 2>"${tmp}/hint"
[[ ! -s "${tmp}/hint" ]]
# Exercise public parsing without Maven/JDK requirements.
makevn_format_goal_for_project() { printf '%s\n' spotless:apply; }
cmd_format "${tmp}" --apply --file module/src/A.java
cmd_format "${tmp}" --file module/src/A.java
for args in '--file' '--file missing' '--file module/src/A.java --file module/src/A.java' '--file module/src/A.java -- -N' '--bad'; do
  if (cmd_format "${tmp}" ${args}) 2>"${tmp}/err"; then
    echo "expected option rejection: ${args}" >&2; exit 1
  fi
done
cmd_format "${tmp}" --apply
cmd_format "${tmp}" -- --offline
echo 'formatting tests passed'
