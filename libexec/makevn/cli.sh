#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/docker.sh"

show_help() {
  cat <<EOF
makevn ${MAKEVN_VERSION}

Terminal-first workflows for Java Maven repositories.

If a repository already uses Maven, local build and test flows should be runnable
from the terminal without IDE-specific setup. Agents in OpenCode should prefer
'makevn' commands over editor-specific instructions.

Usage:
  makevn [--repo PATH] doctor
  makevn [--repo PATH] init [--mode MODE] [--dry-run] [--write-make-include]
  makevn [--repo PATH] uninstall [--dry-run]
  makevn [--repo PATH] profile refresh
  makevn [--repo PATH] compile [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] compile-tests [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] validate [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] package [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] build [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] clean [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] test [--name TEST]... [--fast] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify-ut [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify-ut-coverage [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify-it [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify-it-coverage [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify-changes [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] pr-verify [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] docker-up
  makevn [--repo PATH] docker-down
  makevn [--repo PATH] docker-ps
  makevn [--repo PATH] docker-ps-required
  makevn [--repo PATH] run
  makevn [--repo PATH] exec [--context code|karate] -- COMMAND [ARGS...]
  makevn [--repo PATH] jdk current
  makevn [--repo PATH] jdk list

Modes:
  standalone
  make-include
  make-bootstrap
  auto

Examples:
  makevn doctor
  makevn init --mode standalone
  makevn profile refresh
  makevn compile
  makevn compile-tests
  makevn validate
  makevn package
  makevn build
  makevn clean
  makevn test --name UserRepositoryTest
  makevn test --name UserRepositoryTest,OrderRepositoryTest
  makevn test --name UserRepositoryTest --name OrderRepositoryTest
  makevn test --fast --name UserRepositoryTest
  makevn verify-ut
  makevn verify-ut-coverage
  makevn verify-it
  makevn verify-changes
  makevn pr-verify
  makevn docker-up
  makevn docker-ps-required
  makevn exec -- mvn -q -v
  make -f .makevn/makevn.mk vn-doctor

Notes:
  - 'doctor' inspects the repository and recommends the least invasive mode.
  - 'standalone' keeps everything under '.makevn/' and leaves root makefiles alone.
  - 'make-include' adds optional namespaced 'vn-*' targets without taking over repo-owned targets.
  - 'make-bootstrap' is only for repositories that do not already have a make entrypoint.
EOF
}

print_command_intro() {
  local repo_root="$1"
  local title="$2"

  makevn_print_header "makevn ${title}"
}

print_doctor() {
  local repo_root="$1"

  print_command_intro "${repo_root}" doctor
  makevn_collect_doctor_snapshot "${repo_root}"

  makevn_print_header "Repository analysis"
  makevn_print_item "Repo root" "${MAKEVN_DOCTOR_REPO_ROOT}"
  makevn_print_item "Java Maven repo" "${MAKEVN_DOCTOR_JAVA_MAVEN_REPO}"
  makevn_print_item "Maven base path" "${MAKEVN_DOCTOR_MAVEN_BASE_PATH}"
  makevn_print_item "Existing Makefile" "${MAKEVN_DOCTOR_EXISTING_MAKEFILE}"
  makevn_print_item "Existing GNUmakefile" "${MAKEVN_DOCTOR_EXISTING_GNUMAKEFILE}"
  makevn_print_item "Existing .makevn/" "${MAKEVN_DOCTOR_EXISTING_STATE_DIR}"
  makevn_print_item "Current makevn mode" "${MAKEVN_DOCTOR_CURRENT_MODE}"
  makevn_print_item "Code .tool-versions" "${MAKEVN_DOCTOR_CODE_TOOL_VERSIONS}"
  makevn_print_item "Karate .tool-versions" "${MAKEVN_DOCTOR_KARATE_TOOL_VERSIONS}"
  makevn_print_item "Detected workflow files" "${MAKEVN_DOCTOR_DETECTED_WORKFLOW_FILES}"
  makevn_print_item "Detected Maven CLI flags" "${MAKEVN_DOCTOR_DETECTED_MAVEN_CLI_FLAGS}"
  makevn_print_item "Detected Maven prop flags" "${MAKEVN_DOCTOR_DETECTED_MAVEN_PROP_FLAGS}"
  makevn_print_item "Detected Maven cache" "${MAKEVN_DOCTOR_DETECTED_MAVEN_CACHE_SOURCE}"
  makevn_print_item "Compile profile" "${MAKEVN_DOCTOR_COMPILE_PROFILE}"
  makevn_print_item "Build profile" "${MAKEVN_DOCTOR_BUILD_PROFILE}"
  makevn_print_item "Test profile" "${MAKEVN_DOCTOR_TEST_PROFILE}"
  makevn_print_item "Verify profile" "${MAKEVN_DOCTOR_VERIFY_PROFILE}"
  makevn_print_item "Resolved code JAVA_HOME" "${MAKEVN_DOCTOR_CODE_JAVA_HOME}"
  if [[ -n "${MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE}" ]]; then
    printf '  %s\n' "$(makevn_dim "${MAKEVN_DOCTOR_CODE_JAVA_VERSION_LINE}")"
  fi
  makevn_print_item "Resolved karate JAVA_HOME" "${MAKEVN_DOCTOR_KARATE_JAVA_HOME}"
  if [[ -n "${MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE}" ]]; then
    printf '  %s\n' "$(makevn_dim "${MAKEVN_DOCTOR_KARATE_JAVA_VERSION_LINE}")"
  fi
  makevn_print_item "Run command configured" "${MAKEVN_DOCTOR_RUN_CONFIGURED}"
  makevn_print_item "Persisted profile" "${MAKEVN_DOCTOR_PROFILE_STATUS}"
  makevn_print_item "Recommended mode" "${MAKEVN_DOCTOR_RECOMMENDED_MODE}"

  printf '\n'
  makevn_print_header "Suggested next step"
  if [[ -n "${MAKEVN_DOCTOR_SUGGESTED_NEXT}" ]]; then
    makevn_print_item "next" "${MAKEVN_DOCTOR_SUGGESTED_NEXT}"
  fi
  if [[ -n "${MAKEVN_DOCTOR_SUGGESTED_NOTE}" ]]; then
    makevn_print_item "note" "${MAKEVN_DOCTOR_SUGGESTED_NOTE}"
  fi
  if [[ -n "${MAKEVN_DOCTOR_SUGGESTED_OPTIONAL}" ]]; then
    makevn_print_item "optional" "${MAKEVN_DOCTOR_SUGGESTED_OPTIONAL}"
  fi
}

cmd_init() {
  local repo_root="$1"
  local mode="auto"
  local dry_run=false
  local write_make_include=false
  local force=false
  local resolved_mode
  local state_dir
  local config_path
  local logs_dir
  local make_include_path
  local managed_makefile=""
  local generated_root_makefile=""
  local existing_manifest

  print_command_intro "${repo_root}" init

  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        [[ $# -ge 2 ]] || makevn_die "Missing value for --mode"
        mode="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --write-make-include)
        write_make_include=true
        shift
        ;;
      --force)
        force=true
        shift
        ;;
      *)
        makevn_die "Unknown init option: $1"
        ;;
    esac
  done

  case "${mode}" in
    auto)
      resolved_mode="$(makevn_recommended_mode "${repo_root}")"
      if [[ "${resolved_mode}" == "unsupported" ]]; then
        makevn_die "auto mode only works for detected Java Maven repositories. Use an explicit --mode if you still want local scaffolding."
      fi
      ;;
    standalone|make-include|make-bootstrap)
      resolved_mode="${mode}"
      ;;
    *)
      makevn_die "Unsupported mode: ${mode}"
      ;;
  esac

  if [[ "${resolved_mode}" == "make-bootstrap" ]] && [[ -f "${repo_root}/Makefile" || -f "${repo_root}/GNUmakefile" ]]; then
    makevn_die "make-bootstrap is only allowed when the repo has no Makefile or GNUmakefile"
  fi

  if [[ "${resolved_mode}" != "make-include" && "${write_make_include}" == true ]]; then
    makevn_die "--write-make-include only works with --mode make-include"
  fi

  existing_manifest="$(makevn_manifest_path "${repo_root}")"
  if [[ -f "${existing_manifest}" && "${force}" != true ]]; then
    if [[ "$(makevn_manifest_value "${repo_root}" mode || true)" == "${resolved_mode}" && "${write_make_include}" == false ]]; then
      printf '%s\n' "$(makevn_warn "makevn is already initialized in ${resolved_mode} mode.")"
      return 0
    fi
    makevn_die "makevn is already initialized. Run 'makevn uninstall' first or use --force."
  fi

  state_dir="$(makevn_state_dir "${repo_root}")"
  config_path="$(makevn_config_path "${repo_root}")"
  logs_dir="$(makevn_logs_dir "${repo_root}")"
  make_include_path="${state_dir}/makevn.mk"

  if [[ "${dry_run}" == true ]]; then
    makevn_print_header "Dry run"
    makevn_print_item "repo root" "${repo_root}"
    makevn_print_item "mode" "${resolved_mode}"
    makevn_print_item "would create" "${state_dir}"
    makevn_print_item "would create" "${config_path}"
    makevn_print_item "would create" "$(makevn_profile_path "${repo_root}")"
    makevn_print_item "would create" "${logs_dir}"
    if [[ "${resolved_mode}" != "standalone" ]]; then
      makevn_print_item "would create" "${make_include_path}"
    fi
    if [[ "${resolved_mode}" == "make-bootstrap" ]]; then
      makevn_print_item "would create" "${repo_root}/Makefile"
    fi
    if [[ "${write_make_include}" == true ]]; then
      makevn_print_item "would update" "$(makevn_single_existing_makefile_path "${repo_root}")"
    fi
    return 0
  fi

  mkdir -p "${logs_dir}"
  [[ -f "${config_path}" && "${force}" != true ]] || makevn_write_config "${repo_root}"
  makevn_refresh_profile "${repo_root}"

  if [[ "${resolved_mode}" != "standalone" ]]; then
    makevn_render_make_include "${MAKEVN_BIN_PATH}" > "${make_include_path}"
  else
    rm -f "${make_include_path}"
  fi

  if [[ "${resolved_mode}" == "make-bootstrap" ]]; then
    makevn_write_bootstrap_makefile "${repo_root}"
    generated_root_makefile="Makefile"
  fi

  if [[ "${write_make_include}" == true ]]; then
    managed_makefile="$(basename "$(makevn_single_existing_makefile_path "${repo_root}")")"
    makevn_insert_include_block "${repo_root}/${managed_makefile}"
  fi

  makevn_write_state_json "${repo_root}" "${resolved_mode}" "${managed_makefile}" "${generated_root_makefile}"
  makevn_write_manifest "${repo_root}" "${resolved_mode}" "${managed_makefile}" "${generated_root_makefile}"

  printf '%s\n' "$(makevn_accent "Initialized makevn in ${resolved_mode} mode.")"
  makevn_print_item "created" ".makevn/config"
  makevn_print_item "created" ".makevn/profile.env"
  makevn_print_item "created" ".makevn/logs/"
  if [[ "${resolved_mode}" != "standalone" ]]; then
    makevn_print_item "created" ".makevn/makevn.mk"
  fi
  if [[ -n "${managed_makefile}" ]]; then
    makevn_print_item "updated" "${managed_makefile}"
  fi
  if [[ -n "${generated_root_makefile}" ]]; then
    makevn_print_item "created" "${generated_root_makefile}"
  fi
}

cmd_uninstall() {
  local repo_root="$1"
  local dry_run=false
  local manifest_path
  local managed_makefile
  local generated_root_makefile

  print_command_intro "${repo_root}" uninstall

  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        makevn_die "Unknown uninstall option: $1"
        ;;
    esac
  done

  manifest_path="$(makevn_manifest_path "${repo_root}")"
  [[ -f "${manifest_path}" ]] || makevn_die "makevn is not initialized in ${repo_root}"

  managed_makefile="$(makevn_manifest_value "${repo_root}" managed_makefile || true)"
  generated_root_makefile="$(makevn_manifest_value "${repo_root}" generated_root_makefile || true)"

  if [[ "${dry_run}" == true ]]; then
    makevn_print_header "Uninstall dry run"
    [[ -n "${managed_makefile}" ]] && makevn_print_item "would remove include block from" "${managed_makefile}"
    if [[ -n "${generated_root_makefile}" ]]; then
      if makevn_is_managed_bootstrap_makefile "${repo_root}"; then
        makevn_print_item "would remove root file" "${generated_root_makefile}"
      else
        makevn_print_item "would leave modified root file untouched" "${generated_root_makefile}"
      fi
    fi
    makevn_print_item "would remove" ".makevn/"
    return 0
  fi

  if [[ -n "${managed_makefile}" && -f "${repo_root}/${managed_makefile}" ]]; then
    makevn_remove_include_block "${repo_root}/${managed_makefile}"
  fi

  if [[ -n "${generated_root_makefile}" ]]; then
    if makevn_is_managed_bootstrap_makefile "${repo_root}"; then
      rm -f "${repo_root}/${generated_root_makefile}"
    else
      printf '%s\n' "$(makevn_warn "Warning: ${generated_root_makefile} was modified after initialization and was left untouched.")" >&2
    fi
  fi

  rm -rf "$(makevn_state_dir "${repo_root}")"
  printf '%s\n' "$(makevn_accent "makevn removed from ${repo_root}")"
}

cmd_profile_refresh() {
  local repo_root="$1"
  local profile_path
  local make_include_path

  print_command_intro "${repo_root}" "profile refresh"

  shift
  [[ $# -eq 0 ]] || makevn_die "Usage: makevn profile refresh"

  [[ -f "$(makevn_manifest_path "${repo_root}")" ]] || makevn_die "makevn is not initialized in ${repo_root}. Run 'makevn init --mode ...' first."

  makevn_refresh_profile "${repo_root}"
  profile_path="$(makevn_profile_path "${repo_root}")"
  make_include_path="$(makevn_state_dir "${repo_root}")/makevn.mk"

  if [[ -f "${make_include_path}" ]]; then
    makevn_render_make_include "${MAKEVN_BIN_PATH}" > "${make_include_path}"
  fi

  printf '%s\n' "$(makevn_accent "Profile refreshed.")"
  makevn_print_item "profile" ".makevn/profile.env"
  if [[ -f "${make_include_path}" ]]; then
    makevn_print_item "updated" ".makevn/makevn.mk"
  fi
  makevn_print_item "cache source" "${MAKEVN_DETECTED_MAVEN_CACHE_SOURCE:-unresolved}"
  makevn_print_item "workflows" "${MAKEVN_DETECTED_WORKFLOW_FILES:-none}"
  [[ -f "${profile_path}" ]] || makevn_die "Profile refresh failed: ${profile_path} was not created"
}

cmd_exec() {
  local repo_root="$1"
  local context="code"
  local maven_base_path

  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context)
        [[ $# -ge 2 ]] || makevn_die "Missing value for --context"
        context="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        makevn_die "exec requires '--' before the command"
        ;;
    esac
  done

  [[ $# -gt 0 ]] || makevn_die "No command provided to exec"
  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  print_command_intro "${repo_root}" "exec --context ${context}"
  makevn_run_in_context "${repo_root}" "${context}" "${maven_base_path}" "$@"
}

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
  makevn_run_maven_goal "${repo_root}" verify verify verify "$@"
}

cmd_verify_changes() {
  local repo_root="$1"
  local maven_base_path=""
  local maven_executable=""
  local maven_base_rel=""
  local path_prefix_regex=""
  local strip_prefix=""
  local parent_spec=""
  local diff_base=""
  local diff_local=""
  local changed_src=""
  local changed_test=""
  local modules=""
  local test_list=""
  local module_selection=""
  local jacoco_module=""
  local local_containers="${LOCAL_CONTAINERS:-TRUE}"
  local cli_flags_value=""
  local log_name="verify-changes"
  local rc=0
  local -a cli_flags=()
  local -a extra_args
  local -a build_args=()
  local -a verify_args=()

  shift
  extra_args=()
  if [[ "${1:-}" == "--" ]]; then
    shift
    extra_args=("$@")
  elif [[ $# -gt 0 ]]; then
    makevn_die "verify-changes only accepts extra Maven args after '--'"
  fi

  print_command_intro "${repo_root}" verify-changes

  git -C "${repo_root}" rev-parse HEAD >/dev/null 2>&1 || makevn_die "Not a git repository"

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${maven_base_path}" ]] || makevn_die "No Maven project detected in ${repo_root}"
  maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
  if [[ "${maven_base_path}" == "${repo_root}" ]]; then
    path_prefix_regex='^'
    strip_prefix=''
  else
    maven_base_rel="${maven_base_path#${repo_root}/}"
    path_prefix_regex="^${maven_base_rel}/"
    strip_prefix="${maven_base_rel}/"
  fi

  parent_spec="$(makevn_detect_parent_branch_spec "${repo_root}")"
  makevn_print_item "compare against" "${parent_spec}"

  if [[ "${parent_spec}" == "HEAD" ]]; then
    diff_local="$(git -C "${repo_root}" diff --name-only HEAD || true)"
    changed_src="$(printf '%s\n' "${diff_local}" | grep -E "${path_prefix_regex}.*src/main/java/.*\.java$" || true)"
    changed_test="$(printf '%s\n' "${diff_local}" | grep -E "${path_prefix_regex}.*src/test/java/.*\.java$" || true)"
  else
    diff_base="$(git -C "${repo_root}" diff --name-only "${parent_spec}" || true)"
    diff_local="$(git -C "${repo_root}" diff --name-only HEAD || true)"
    changed_src="$(printf '%s\n%s\n' "${diff_base}" "${diff_local}" | grep -E "${path_prefix_regex}.*src/main/java/.*\.java$" | LC_ALL=C sort -u || true)"
    changed_test="$(printf '%s\n%s\n' "${diff_base}" "${diff_local}" | grep -E "${path_prefix_regex}.*src/test/java/.*\.java$" | LC_ALL=C sort -u || true)"
  fi

  if [[ -z "${changed_src}" && -z "${changed_test}" ]]; then
    printf '%s\n' "$(makevn_dim "No modified Java files detected. Skipping verify-changes.")"
    return 0
  fi

  cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" verify)"
  cli_flags_value="$(makevn_append_word "${cli_flags_value}" "-nsu")"
  if [[ -n "${cli_flags_value}" ]]; then
    read -r -a cli_flags <<< "${cli_flags_value}"
  fi

  if [[ -n "${changed_src}" ]]; then
    modules="$(printf '%s\n' "${changed_src}" | sed "s|^${strip_prefix}||" | sed 's|/src/.*||' | LC_ALL=C sort -u | paste -sd, -)"
    if [[ -z "${modules}" ]]; then
      cmd_verify "${repo_root}"
      return $?
    fi

    build_args=("${maven_executable}")
    if [[ ${#cli_flags[@]} -gt 0 ]]; then
      build_args+=("${cli_flags[@]}")
    fi
    build_args+=(-f "${maven_base_path}/pom.xml" -pl "${modules}" -am install -DskipTests -Damiga-javaformat.skip=true -Dmaven.build.cache.enabled=false)
    if [[ ${#extra_args[@]} -gt 0 ]]; then
      build_args+=("${extra_args[@]}")
    fi
    makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" verify-changes-build verify-changes "verify-changes build" "${build_args[@]}"
    rc=$?
    [[ ${rc} -eq 0 ]] || return ${rc}

    jacoco_module="$(makevn_detect_jacoco_module_name "${maven_base_path}" || true)"
    module_selection="${modules}"
    if [[ -n "${jacoco_module}" && ",${modules}," != *",${jacoco_module},"* ]]; then
      module_selection="${modules},${jacoco_module}"
    fi

    verify_args=("${maven_executable}")
    if [[ ${#cli_flags[@]} -gt 0 ]]; then
      verify_args+=("${cli_flags[@]}")
    fi
    verify_args+=(-f "${maven_base_path}/pom.xml" -pl "${module_selection}" verify -Djacoco.skip=false -Damiga.jacoco -DskipTests=false -Dmaven.test.failure.ignore=false -Damiga-javaformat.skip=true -Dmaven.build.cache.enabled=false)
    if [[ ${#extra_args[@]} -gt 0 ]]; then
      verify_args+=("${extra_args[@]}")
    fi
    makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" "${log_name}" verify-changes "verify-changes" "${verify_args[@]}"
    rc=$?
    [[ ${rc} -eq 0 ]] && makevn_print_jacoco_report_hint "${maven_base_path}"
    return ${rc}
  fi

  test_list="$(printf '%s\n' "${changed_test}" | sed "s|^${strip_prefix}||" | sed 's|^.*/src/test/java/||' | sed 's|\.java$||' | tr '/' '.' | paste -sd, -)"
  verify_args=(env "LOCAL_CONTAINERS=${local_containers}" "${maven_executable}")
  if [[ ${#cli_flags[@]} -gt 0 ]]; then
    verify_args+=("${cli_flags[@]}")
  fi
  verify_args+=(-f "${maven_base_path}/pom.xml" verify -Damiga-javaformat.skip=true -DskipUTs=false -Dtest="${test_list}" -Dit.test="${test_list}" -Dfailsafe.failIfNoSpecifiedTests=false -Dsurefire.failIfNoSpecifiedTests=false -Dawaitility.defaultPollInterval=200ms -Dawaitility.defaultTimeout=2m -Djacoco.skip=false -Damiga.jacoco -Dmaven.build.cache.enabled=false)
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    verify_args+=("${extra_args[@]}")
  fi
  makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" "${log_name}" verify-changes "verify-changes" "${verify_args[@]}"
  rc=$?
  [[ ${rc} -eq 0 ]] && makevn_print_jacoco_report_hint "${maven_base_path}"
  return ${rc}
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

cmd_run() {
  local repo_root="$1"
  local maven_base_path
  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  print_command_intro "${repo_root}" run
  makevn_run_command_configured "${repo_root}" "${maven_base_path}"
}

cmd_jdk_current() {
  local repo_root="$1"
  local maven_base_path
  local code_tool_versions=""
  local karate_tool_versions=""
  local jdk_manager

  print_command_intro "${repo_root}" "jdk current"

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  code_tool_versions="$(makevn_detect_code_tool_versions "${repo_root}" "${maven_base_path}" || true)"
  karate_tool_versions="$(makevn_detect_karate_tool_versions "${repo_root}" || true)"
  jdk_manager="$(makevn_jdk_manager_script)"
  bash "${jdk_manager}" current-contexts "${code_tool_versions}" "${karate_tool_versions}"
}

cmd_jdk_list() {
  local jdk_manager
  local repo_root="${1:-$PWD}"
  print_command_intro "${repo_root}" "jdk list"
  jdk_manager="$(makevn_jdk_manager_script)"
  bash "${jdk_manager}" list
}

REPO_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || makevn_die "Missing value for --repo"
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    --version)
      printf '%s\n' "${MAKEVN_VERSION}"
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift

REPO_ROOT="$(makevn_resolve_repo_root "${REPO_OVERRIDE:-$PWD}")"

case "${COMMAND}" in
  help)
    makevn_print_header "makevn help"
    show_help
    ;;
  doctor)
    print_doctor "${REPO_ROOT}"
    ;;
  init)
    cmd_init "${REPO_ROOT}" "$@"
    ;;
  uninstall)
    cmd_uninstall "${REPO_ROOT}" "$@"
    ;;
  profile)
    SUBCOMMAND="${1:-}"
    case "${SUBCOMMAND}" in
      refresh)
        shift
        cmd_profile_refresh "${REPO_ROOT}" "$@"
        ;;
      *)
        makevn_die "Usage: makevn profile refresh"
        ;;
    esac
    ;;
  exec)
    cmd_exec "${REPO_ROOT}" "$@"
    ;;
  compile)
    cmd_compile "${REPO_ROOT}" "$@"
    ;;
  compile-tests)
    cmd_compile_tests "${REPO_ROOT}" "$@"
    ;;
  validate)
    cmd_validate "${REPO_ROOT}" "$@"
    ;;
  package)
    cmd_package "${REPO_ROOT}" "$@"
    ;;
  clean)
    cmd_clean "${REPO_ROOT}" "$@"
    ;;
  build)
    cmd_build "${REPO_ROOT}" "$@"
    ;;
  test)
    cmd_test "${REPO_ROOT}" "$@"
    ;;
  verify-ut)
    cmd_verify_ut "${REPO_ROOT}" "$@"
    ;;
  verify-ut-coverage)
    cmd_verify_ut_coverage "${REPO_ROOT}" "$@"
    ;;
  verify-it)
    cmd_verify_it "${REPO_ROOT}" "$@"
    ;;
  verify-it-coverage)
    cmd_verify_it_coverage "${REPO_ROOT}" "$@"
    ;;
  verify)
    cmd_verify "${REPO_ROOT}" "$@"
    ;;
  verify-changes)
    cmd_verify_changes "${REPO_ROOT}" "$@"
    ;;
  pr-verify)
    cmd_pr_verify "${REPO_ROOT}" "$@"
    ;;
  docker-up)
    cmd_docker_up "${REPO_ROOT}" "$@"
    ;;
  docker-down)
    cmd_docker_down "${REPO_ROOT}" "$@"
    ;;
  docker-ps)
    cmd_docker_ps "${REPO_ROOT}" "$@"
    ;;
  docker-ps-required)
    cmd_docker_ps_required "${REPO_ROOT}" "$@"
    ;;
  run)
    cmd_run "${REPO_ROOT}" "$@"
    ;;
  jdk)
    SUBCOMMAND="${1:-}"
    case "${SUBCOMMAND}" in
      current)
        cmd_jdk_current "${REPO_ROOT}"
        ;;
      list)
        cmd_jdk_list "${REPO_ROOT}"
        ;;
      *)
        makevn_die "Usage: makevn jdk current|list"
        ;;
    esac
    ;;
  *)
    makevn_die "Unknown command: ${COMMAND}"
    ;;
esac
