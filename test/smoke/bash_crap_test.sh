#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/libexec/makevn/common.sh"
source "${ROOT_DIR}/libexec/makevn/commands/init.sh"
source "${ROOT_DIR}/libexec/makevn/commands/maven.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/makevn-bash-crap.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

assert_equal() {
  [[ "$1" == "$2" ]] || { printf 'Expected <%s>, got <%s>\n' "$2" "$1" >&2; exit 1; }
}

assert_rejected() {
  local expected="$1"
  shift
  if ("$@") >"${TMP_ROOT}/error" 2>&1; then
    printf 'Expected rejection: %s\n' "$*" >&2
    exit 1
  fi
  grep -Fq -- "${expected}" "${TMP_ROOT}/error"
}

test_option_parsers() {
  local dry_run=false force=false
  cmd_init_parse_options --dry-run --force
  assert_equal "${dry_run}:${force}" true:true
  dry_run=false
  cmd_uninstall_parse_options --dry-run
  assert_equal "${dry_run}" true
  assert_rejected 'Unknown init option: --bad' cmd_init_parse_options --bad
  assert_rejected 'Unknown uninstall option: --bad' cmd_uninstall_parse_options --bad

  local fast_mode=false name_arg='' test_name=''
  local -a name_args=() split_names=() test_names=() extra_args=()
  makevn_parse_test_options --name ' Alpha, ,Beta ' --name Gamma --fast -- '-Dvalue=two words' --name
  makevn_collect_test_names
  assert_equal "${fast_mode}" true
  assert_equal "${test_names[*]}" 'Alpha Beta Gamma'
  assert_equal "${#extra_args[@]}" 2
  assert_equal "${extra_args[0]}" '-Dvalue=two words'
  assert_equal "${extra_args[1]}" --name
  assert_rejected 'Missing value for --name' makevn_parse_test_options --name
  assert_rejected 'Unknown test option: --bad' makevn_parse_test_options --bad

  local module='' verbose=false
  extra_args=()
  makevn_parse_checkstyle_options --module 'module with spaces' --verbose -- '-Dvalue=two words'
  assert_equal "${module}" 'module with spaces'
  assert_equal "${verbose}" true
  assert_equal "${extra_args[0]}" '-Dvalue=two words'
  assert_rejected 'Missing value for --module' makevn_parse_checkstyle_options --module
  assert_rejected 'Unknown checkstyle option: --bad' makevn_parse_checkstyle_options --bad
}

test_checkstyle_arguments() {
  local repo_root="${TMP_ROOT}/project" maven_base_path="${TMP_ROOT}/project/code" maven_base_rel=''
  mkdir -p "${maven_base_path}"
  touch "${maven_base_path}/pom.xml"
  local module=code verbose=false maven_executable='mvn with spaces' checkstyle_goal=checkstyle:check
  local -a maven_cli_flags=() maven_args=() extra_args=()
  makevn_normalize_checkstyle_module "${repo_root}" "${maven_base_path}"
  assert_equal "${module}" ''
  makevn_build_checkstyle_args
  assert_equal "${#maven_args[@]}" 5
  assert_equal "${maven_args[0]}" 'mvn with spaces'
  assert_equal "${maven_args[1]}" -q
  assert_equal "${maven_args[3]}" "${maven_base_path}/pom.xml"
  module=child verbose=true
  maven_cli_flags=(-B) extra_args=('-Dvalue=two words')
  makevn_build_checkstyle_args
  assert_equal "${maven_args[*]}" "mvn with spaces -B -f ${maven_base_path}/pom.xml -pl child checkstyle:check -Dcheckstyle.consoleOutput=true -Dvalue=two words"
}

test_goal_flag_arrays() {
  local maven_cli_flags_value='-B -ntp' maven_prop_flags_value='-Dflag=true' command_pre_goals_value='clean validate'
  local -a maven_cli_flags=() maven_prop_flags=() command_pre_goals=()
  makevn_parse_goal_flags
  assert_equal "${maven_cli_flags[*]}" '-B -ntp'
  assert_equal "${maven_prop_flags[*]}" '-Dflag=true'
  assert_equal "${command_pre_goals[*]}" 'clean validate'
  maven_cli_flags_value='' maven_prop_flags_value='' command_pre_goals_value=''
  maven_cli_flags=() maven_prop_flags=() command_pre_goals=()
  makevn_parse_goal_flags
  assert_equal "${#maven_cli_flags[@]}:${#maven_prop_flags[@]}:${#command_pre_goals[@]}" 0:0:0
}

test_verify_it_workflow_flags() {
  local token='' skip_next=false local_containers='' maven_executable=mvn maven_base_path='root with spaces'
  local -a workflow_tokens=(mvn -f old/pom.xml --file other.xml install -DskipITs=true -Dmaven.build.cache.enabled=true -B -Dkeep=yes)
  local -a maven_args=() maven_cli_flags=() filtered_prop_flags=()
  makevn_append_verify_it_workflow_tokens
  assert_equal "${maven_args[*]}" 'verify -B -Dkeep=yes'
  local maven_cli_flags_value='' filtered_prop_flags_value='-DskipUTs'
  makevn_build_verify_it_fallback_args
  assert_equal "${maven_args[*]}" 'mvn -f root with spaces/pom.xml verify -DskipUTs'
  local_containers=true maven_cli_flags_value=-B filtered_prop_flags_value=''
  makevn_build_verify_it_fallback_args '-Dvalue=two words'
  assert_equal "${maven_args[*]}" 'env LOCAL_CONTAINERS=true mvn -B -f root with spaces/pom.xml verify -Dvalue=two words'
}

test_selected_test_execution() (
  # Record exact argument boundaries without invoking a real Maven executable.
  makevn_run_selected_test() { printf '%s\n' "$@" >>"${TMP_ROOT}/selected"; }
  cmd_test 'root with spaces' --name 'Alpha,Beta' --fast -- '-Dvalue=two words' >"${TMP_ROOT}/output"
  assert_equal "$(cat "${TMP_ROOT}/selected")" "$(printf '%s\n' 'root with spaces' Alpha true '-Dvalue=two words' 'root with spaces' Beta true '-Dvalue=two words')"
  grep -Fq 'ok selected tests completed' "${TMP_ROOT}/output"
  assert_rejected 'test --fast requires at least one --name' cmd_test root --fast
)


test_all_test_exit_status() (
  makevn_run_maven_goal() { return 17; }
  makevn_logs_dir() { printf '%s' "${TMP_ROOT}"; }
  makevn_hint_stale_generated_sources_if_needed() { printf 'hint\n' >"${TMP_ROOT}/hint"; }
  local rc=0
  # This is how callers that collect failures suppress errexit; keep the failure code.
  cmd_test root -- '-Dvalue=two words' >"${TMP_ROOT}/all-output" || rc=$?
  assert_equal "${rc}" 17
  assert_equal "$(cat "${TMP_ROOT}/hint")" hint
)


test_failed_selected_test_sequence() (
  makevn_run_selected_test() {
    printf '%s\n' "$2" >>"${TMP_ROOT}/failed-selected"
    [[ "$2" != Alpha ]]
  }
  local rc=0
  cmd_test root --name Alpha --name Beta >"${TMP_ROOT}/failed-output" 2>&1 || rc=$?
  assert_equal "${rc}" 1
  assert_equal "$(cat "${TMP_ROOT}/failed-selected")" "$(printf 'Alpha\nBeta')"
  grep -Fq 'some selected tests failed: Alpha' "${TMP_ROOT}/failed-output"
)

test_verify_it_property_filtering() (
  makevn_append_coverage_prop_flags() { printf '%s' "$2 -Djacoco.skip=false"; }
  local repo_root=root token='' maven_prop_flags_value='-Dkeep=yes -Dmaven.build.cache.enabled=true'
  local filtered_prop_flags_value=''
  makevn_prepare_verify_it_properties
  assert_equal "${filtered_prop_flags_value}" '-Dkeep=yes -Djacoco.skip=false -DskipUTs -Dskip.unit.tests=true -DfailIfNoTests=false -Dmaven.test.failure.ignore=false -Dmaven.build.cache.enabled=false'
)


test_option_parsers
test_checkstyle_arguments
test_goal_flag_arrays
test_verify_it_workflow_flags
test_selected_test_execution
test_all_test_exit_status
test_failed_selected_test_sequence
test_verify_it_property_filtering
printf 'Bash CRAP regression tests passed\n'
