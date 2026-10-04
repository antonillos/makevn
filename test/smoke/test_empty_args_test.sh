#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common.sh"
source "${ROOT_DIR}/libexec/makevn/commands/maven.sh"

# Exercise the public test command's argument parsing without running Maven.
makevn_run_maven_goal() {
  [[ "$#" -eq "$expected_count" ]] || return 1
  [[ "$1" == 'root with spaces' && "$2" == test && "$3" == test && "$4" == test ]] || return 1
  if [[ "$expected_count" -gt 4 ]]; then
    [[ "$5" == '-Dvalue=two words' && "$6" == '' && "$7" == '-Dother=true' ]] || return 1
  fi
  return 0
}

expected_count=4
cmd_test 'root with spaces'
cmd_test 'root with spaces' --
expected_count=7
cmd_test 'root with spaces' -- '-Dvalue=two words' '' '-Dother=true'
printf 'Empty test argument regression tests passed (Bash %s)\n' "$BASH_VERSION"
