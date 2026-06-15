#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

show_help() {
  cat <<EOF
makevn ${MAKEVN_VERSION}

Terminal-first workflows for Java Maven repositories.

If a repository already uses Maven, local build and test flows should be runnable
from the terminal without IDE-specific setup. Agents in OpenCode should prefer
'makevn' commands over editor-specific instructions.

Usage:
  makevn [--repo PATH] [--compact] doctor
  makevn [--repo PATH] [--compact] init [--dry-run] [--force]
  makevn [--repo PATH] refresh [--dry-run]
  makevn [--repo PATH] [--compact] make install [--dry-run]
  makevn [--repo PATH] [--compact] make uninstall [--dry-run]
  makevn [--repo PATH] [--compact] uninstall [--dry-run]
  makevn [--repo PATH] [--compact] profile refresh
  makevn [--repo PATH] [--compact] compile [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] test-compile [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] compile-tests [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] validate [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] package [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] build [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] clean [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] test [--name TEST]... [--fast] [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify-ut [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify-ut-coverage [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify-it [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify-it-coverage [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] verify-changes [--clean-generated-contract-targets] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] coverage [--threshold PCT]
  makevn [--repo PATH] coverage-changes [--threshold PCT] [--overall-threshold PCT] [--verbose]
  makevn [--repo PATH] pr-verify [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] format [--apply] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] checkstyle [--module MODULE] [--verbose] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] docker-up [--tail]
  makevn [--repo PATH] docker-down [--tail]
  makevn [--repo PATH] docker-ps [--tail]
  makevn [--repo PATH] docker-stats [--tail]
  makevn [--repo PATH] docker-ps-required [--tail] [--compose boot|karate] [--wait-seconds N]
  makevn [--repo PATH] karate-docker-up [--tail]
  makevn [--repo PATH] karate-docker-down [--tail]
  makevn [--repo PATH] karate-test [--tag TAG] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] karate-all [--tag TAG] [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] run-app
  makevn [--repo PATH] run-app-bg
  makevn [--repo PATH] stop-app
  makevn [--repo PATH] run
  makevn [--repo PATH] exec [--context code|karate] -- COMMAND [ARGS...]
  makevn [--repo PATH] jdk current
  makevn [--repo PATH] jdk list
  makevn [--repo PATH] mutation [--module MODULE] [--verbose]

Examples:
  makevn doctor
  makevn init
  makevn make install
  makevn make uninstall
  makevn profile refresh
  makevn compile
  makevn test-compile
  makevn compile-tests
  makevn validate
  makevn package
  makevn build
  makevn clean
  makevn test --name UserRepositoryTest
  makevn test --name UserRepositoryTest,OrderRepositoryTest
  makevn test --name UserRepositoryTest --name OrderRepositoryTest
  makevn test --fast --name UserRepositoryTest
  makevn test --clean-generated-contract-targets --name UserRepositoryTest
  makevn verify-ut
  makevn verify-ut-coverage
  makevn verify-it
  makevn verify --clean-generated-contract-targets
  makevn coverage
  makevn verify-changes
  makevn coverage-changes
  makevn pr-verify
  makevn format --apply
  makevn checkstyle --module domain --verbose
  makevn docker-up
  makevn docker-stats
  makevn docker-ps-required
  makevn docker-ps-required --compose karate
  makevn docker-ps-required --wait-seconds 15
  makevn karate-test
  makevn karate-test --tag @smoke
  makevn run-app-bg
  makevn stop-app
  makevn exec -- mvn -q -v
  make -f .makevn/makevn.mk vn-doctor

Notes:
  - '--compact' forces agent-style compact output even in a TTY.
  - Non-interactive runs are compact by default: full logs stay under '.makevn/logs/'.
  - 'doctor' inspects the repository before and after initialization.
  - 'init' always creates '.makevn/' without touching root makefiles.
  - 'make install' adds optional 'vn-*' targets by updating one existing makefile or creating a minimal root Makefile.
  - 'make uninstall' removes only the Make integration and keeps '.makevn/' intact.
EOF
}

print_command_intro() {
  local repo_root="$1"
  local title="$2"

  makevn_print_header "makevn ${title}"
}

makevn_cli_is_top_level_command() {
  case "$1" in
    help|doctor|init|make|uninstall|profile|exec|compile|test-compile|compile-tests|validate|package|clean|build|test|verify-ut|verify-ut-coverage|verify-it|verify-it-coverage|verify|verify-changes|coverage|coverage-changes|pr-verify|format|checkstyle|docker-up|docker-down|docker-ps|docker-stats|docker-ps-required|karate-docker-up|karate-docker-down|karate-test|karate-all|run-app|run-app-bg|stop-app|run|jdk|mutation)
      return 0
      ;;
  esac
  return 1
}

makevn_cli_option_takes_value() {
  case "$1" in
    --name|--context|--threshold|--overall-threshold|--tag|--compose|--module)
      return 0
      ;;
  esac
  return 1
}

makevn_cli_dispatch_sequence_if_needed() {
  local repo_root="$1"
  shift

  local -a args=("$@")
  local -a current=()
  local -a segments=()
  local arg=""
  local forwarding_passthrough=false
  local option_expects_value=false
  local segment=""

  [[ ${#args[@]} -gt 0 ]] || return 1

  for arg in "${args[@]}"; do
    if [[ ${#current[@]} -eq 0 ]]; then
      current=("${arg}")
      continue
    fi

    if [[ "${forwarding_passthrough}" == true ]]; then
      current+=("${arg}")
      continue
    fi

    if [[ "${option_expects_value}" == true ]]; then
      current+=("${arg}")
      option_expects_value=false
      continue
    fi

    if [[ "${arg}" == "--" ]]; then
      forwarding_passthrough=true
      current+=("${arg}")
      continue
    fi

    if makevn_cli_option_takes_value "${arg}"; then
      current+=("${arg}")
      option_expects_value=true
      continue
    fi

    if [[ "${current[0]}" == "make" && ${#current[@]} -eq 1 && ( "${arg}" == "install" || "${arg}" == "uninstall" ) ]]; then
      current+=("${arg}")
      continue
    fi

    if makevn_cli_is_top_level_command "${arg}"; then
      segments+=("$(printf '%q ' "${current[@]}")")
      current=("${arg}")
      continue
    fi

    current+=("${arg}")
  done

  segments+=("$(printf '%q ' "${current[@]}")")
  [[ ${#segments[@]} -gt 1 ]] || return 1

  for segment in "${segments[@]}"; do
    eval "set -- ${segment}"
    "${BASH_SOURCE[0]}" --repo "${repo_root}" "$@"
  done
  exit 0
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/doctor.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/init.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/refresh.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/profile.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/exec.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/maven.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/changes.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/docker.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/karate.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/run.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/jdk.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/mutation.sh"

REPO_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || makevn_die "Missing value for --repo"
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    --compact)
      export MAKEVN_COMPACT_OUTPUT=1
      export NO_COLOR=1
      shift
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

REPO_CANDIDATE="${REPO_OVERRIDE:-$PWD}"
case "${COMMAND}" in
  doctor|init)
    makevn_require_repo_path_is_git_root "${REPO_CANDIDATE}" "${COMMAND}"
    ;;
esac

REPO_ROOT="$(makevn_resolve_repo_root "${REPO_CANDIDATE}")"

# Consume --clean-generated-contract-targets flag across all commands
_consumed_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean-generated-contract-targets)
      MAKEVN_CLEAN_GENERATED_CONTRACT_TARGETS=true
      shift
      ;;
    *)
      _consumed_args+=("$1")
      shift
      ;;
  esac
done
[[ ${#_consumed_args[@]} -gt 0 ]] && set -- "${_consumed_args[@]}" || set --

if makevn_cli_dispatch_sequence_if_needed "${REPO_ROOT}" "${COMMAND}" "$@"; then
  exit 0
fi

case "${COMMAND}" in
  help)
    makevn_print_header "makevn help"
    show_help
    ;;
  doctor)
    print_doctor "${REPO_ROOT}" "$@"
    ;;
  refresh)
    cmd_refresh "${REPO_ROOT}" "$@"
    ;;
  init)
    cmd_init "${REPO_ROOT}" "$@"
    ;;
  make)
    SUBCOMMAND="${1:-}"
    case "${SUBCOMMAND}" in
      install)
        shift
        cmd_make_install "${REPO_ROOT}" "$@"
        ;;
      uninstall)
        shift
        cmd_make_uninstall "${REPO_ROOT}" "$@"
        ;;
      *)
        makevn_die "Usage: makevn make install|uninstall"
        ;;
    esac
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
  test-compile)
    cmd_test_compile "${REPO_ROOT}" "$@"
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
  coverage)
    cmd_coverage "${REPO_ROOT}" "$@"
    ;;
  coverage-changes)
    cmd_coverage_changes "${REPO_ROOT}" "$@"
    ;;
  pr-verify)
    cmd_pr_verify "${REPO_ROOT}" "$@"
    ;;
  format)
    cmd_format "${REPO_ROOT}" "$@"
    ;;
  checkstyle)
    cmd_checkstyle "${REPO_ROOT}" "$@"
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
  docker-stats)
    cmd_docker_stats "${REPO_ROOT}" "$@"
    ;;
  docker-ps-required)
    cmd_docker_ps_required "${REPO_ROOT}" "$@"
    ;;
  karate-docker-up)
    cmd_karate_docker_up "${REPO_ROOT}" "$@"
    ;;
  karate-docker-down)
    cmd_karate_docker_down "${REPO_ROOT}" "$@"
    ;;
  karate-test)
    cmd_karate_test "${REPO_ROOT}" "$@"
    ;;
  karate-all)
    cmd_karate_all "${REPO_ROOT}" "$@"
    ;;
  run-app)
    cmd_run_app "${REPO_ROOT}" "$@"
    ;;
  run-app-bg)
    cmd_run_app_bg "${REPO_ROOT}" "$@"
    ;;
  stop-app)
    cmd_stop_app "${REPO_ROOT}" "$@"
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
  mutation)
    cmd_mutation "${REPO_ROOT}" "$@"
    ;;
  *)
    makevn_die "Unknown command: ${COMMAND}"
    ;;
esac
