#!/usr/bin/env bash
set -euo pipefail

cmd_build() {
  local repo_root="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  makevn_run_maven_goal "${repo_root}" package build build -DskipTests "$@"
}

cmd_compile() {
  local repo_root="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  makevn_run_maven_goal "${repo_root}" compile compile compile "$@"
}

cmd_test_compile() {
  local repo_root="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  makevn_run_maven_goal "${repo_root}" test-compile test-compile "" "$@"
}

cmd_compile_tests() {
  local repo_root="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  makevn_run_maven_goal "${repo_root}" test-compile compile-tests "" "$@"
}

cmd_validate() {
  local repo_root="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  makevn_run_maven_goal "${repo_root}" validate validate "" "$@"
}

cmd_package() {
  local repo_root="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  makevn_run_maven_goal "${repo_root}" package package build "$@"
}

cmd_clean() {
  local repo_root="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  makevn_run_maven_goal "${repo_root}" clean clean "" "$@"
}

cmd_test() {
  local repo_root="$1"
  local fast_mode=false
  local name_arg=""
  local test_name=""
  local failed_names=""
  local index=0
  local total=0
  local -a name_args
  local -a split_names
  local -a test_names
  local -a extra_args

  shift
  name_args=()
  split_names=()
  test_names=()
  extra_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ $# -ge 2 ]] || makevn_die "Missing value for --name"
        name_args+=("$2")
        shift 2
        ;;
      --fast)
        fast_mode=true
        shift
        ;;
      --)
        shift
        extra_args=("$@")
        break
        ;;
      *)
        makevn_die "Unknown test option: $1"
        ;;
    esac
  done

  for name_arg in "${name_args[@]-}"; do
    IFS=',' read -r -a split_names <<< "${name_arg}"
    for test_name in "${split_names[@]-}"; do
      test_name="$(makevn_trim "${test_name}")"
      [[ -n "${test_name}" ]] || continue
      test_names+=("${test_name}")
    done
  done

  if [[ "${fast_mode}" == true && ${#test_names[@]} -eq 0 ]]; then
    makevn_die "test --fast requires at least one --name"
  fi

  if [[ ${#test_names[@]} -eq 0 ]]; then
    if [[ ${#extra_args[@]} -gt 0 ]]; then
      makevn_run_maven_goal "${repo_root}" test test test "${extra_args[@]}"
    else
      makevn_run_maven_goal "${repo_root}" test test test
    fi
    return 0
  fi

  if [[ ${#test_names[@]} -eq 1 ]]; then
    if [[ ${#extra_args[@]} -gt 0 ]]; then
      makevn_run_selected_test "${repo_root}" "${test_names[0]}" "${fast_mode}" "${extra_args[@]}"
    else
      makevn_run_selected_test "${repo_root}" "${test_names[0]}" "${fast_mode}"
    fi
    return 0
  fi

  total=${#test_names[@]}
  printf '%s\n' "$(makevn_accent "Running ${total} tests sequentially.")"
  for test_name in "${test_names[@]-}"; do
    index=$((index + 1))
    printf '%s\n' "$(makevn_dim "[${index}/${total}] ${test_name}")"
    if [[ ${#extra_args[@]} -gt 0 ]]; then
      makevn_run_selected_test "${repo_root}" "${test_name}" "${fast_mode}" "${extra_args[@]}"
    else
      makevn_run_selected_test "${repo_root}" "${test_name}" "${fast_mode}"
    fi
    if [[ $? -ne 0 ]]; then
      failed_names="$(makevn_append_word "${failed_names}" "${test_name}")"
    fi
  done

  if [[ -n "${failed_names}" ]]; then
    printf '%s\n' "$(makevn_warn "fail some selected tests failed: ${failed_names}")" >&2
    return 1
  fi

  printf '%s\n' "$(makevn_accent "ok selected tests completed")"
}

cmd_verify_ut() {
  local repo_root="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  makevn_run_maven_goal "${repo_root}" verify verify-ut "" \
    -Djacoco.skip=false \
    -Damiga.jacoco \
    -DskipITs \
    -DfailIfNoTests=false \
    -Dmaven.test.failure.ignore=false \
    "$@"
}

cmd_verify_ut_coverage() {
  local repo_root="$1"
  local maven_base_path=""
  local maven_base_rel=""
  local rc=0

  cmd_verify_ut "${repo_root}" "${@:2}"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
    [[ -n "${maven_base_path}" ]] && makevn_print_jacoco_report_hint "${maven_base_path}"
  fi
  return ${rc}
}

cmd_verify_it() {
  local repo_root="$1"
  shift
  [[ "${1:-}" == "--" ]] && shift
  cmd_docker_ps_required "${repo_root}"
  makevn_run_verify_it_goal "${repo_root}" verify-it "$@"
}

cmd_verify_it_coverage() {
  local repo_root="$1"
  local maven_base_path=""
  local rc=0

  cmd_verify_it "${repo_root}" "${@:2}"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
    [[ -n "${maven_base_path}" ]] && makevn_print_jacoco_report_hint "${maven_base_path}"
  fi
  return ${rc}
}

cmd_verify() {
  local repo_root="$1"
  local arg=""
  local local_containers=""
  shift
  [[ "${1:-}" == "--" ]] && shift
  for arg in "$@"; do
    case "${arg}" in
      -DskipUTs|-DskipUTs=*|-DskipITs|-DskipITs=*|-Dskip.unit.tests=true|-Dskip.unit.tests=false)
        makevn_die "verify does not accept UT/IT skip flags; use verify-ut or verify-it instead"
        ;;
    esac
  done
  cmd_docker_ps_required "${repo_root}"
  makevn_load_profile "${repo_root}"
  local_containers="$(makevn_effective_local_containers "${repo_root}" "${MAKEVN_PROFILE_VERIFY_IT_LOCAL_CONTAINERS:-}")"
  if [[ -n "${local_containers}" ]]; then
    LOCAL_CONTAINERS="${local_containers}" makevn_run_maven_goal "${repo_root}" verify verify verify "$@"
  else
    makevn_run_maven_goal "${repo_root}" verify verify verify "$@"
  fi
}

cmd_pr_verify() {
  local repo_root="$1"
  local maven_base_path=""
  local maven_executable=""
  local cli_flags_value=""
  local rc=0
  local -a cli_flags=()
  local -a extra_args
  local -a maven_args=()

  shift
  extra_args=()
  if [[ "${1:-}" == "--" ]]; then
    shift
    extra_args=("$@")
  elif [[ $# -gt 0 ]]; then
    makevn_die "pr-verify only accepts extra Maven args after '--'"
  fi

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${maven_base_path}" ]] || makevn_die "No Maven project detected in ${repo_root}"
  maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
  cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" verify)"
  cli_flags_value="$(makevn_append_word "${cli_flags_value}" "-B")"
  cli_flags_value="$(makevn_append_word "${cli_flags_value}" "-nsu")"
  if [[ -n "${cli_flags_value}" ]]; then
    read -r -a cli_flags <<< "${cli_flags_value}"
  fi

  maven_args=("${maven_executable}")
  if [[ ${#cli_flags[@]} -gt 0 ]]; then
    maven_args+=("${cli_flags[@]}")
  fi
  maven_args+=(-f "${maven_base_path}/pom.xml" clean verify -Djacoco.skip=false -Damiga.jacoco -DskipITs -DfailIfNoTests=false -Dmaven.test.failure.ignore=false -Damiga-javaformat.skip=true -Dmaven.build.cache.enabled=false)
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    maven_args+=("${extra_args[@]}")
  fi

  makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" pr-verify pr-verify pr-verify "${maven_args[@]}"
  rc=$?
  [[ ${rc} -eq 0 ]] && makevn_print_jacoco_report_hint "${maven_base_path}"
  return ${rc}
}
