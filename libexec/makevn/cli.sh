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
  makevn [--repo PATH] doctor
  makevn [--repo PATH] init [--mode MODE] [--dry-run] [--write-make-include]
  makevn [--repo PATH] uninstall [--dry-run]
  makevn [--repo PATH] profile refresh
  makevn [--repo PATH] compile [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] test-compile [-- EXTRA_MAVEN_ARGS...]
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
  makevn [--repo PATH] coverage-changes [--threshold PCT]
  makevn [--repo PATH] pr-verify [-- EXTRA_MAVEN_ARGS...]
  makevn [--repo PATH] docker-up [--tail]
  makevn [--repo PATH] docker-down [--tail]
  makevn [--repo PATH] docker-ps [--tail]
  makevn [--repo PATH] docker-ps-required [--tail] [--compose boot|karate]
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
  makevn verify-ut
  makevn verify-ut-coverage
  makevn verify-it
  makevn verify-changes
  makevn coverage-changes
  makevn pr-verify
  makevn docker-up
  makevn docker-ps-required
  makevn docker-ps-required --compose karate
  makevn karate-test
  makevn karate-test --tag @smoke
  makevn run-app-bg
  makevn stop-app
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

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/doctor.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/commands/init.sh"
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
  coverage-changes)
    cmd_coverage_changes "${REPO_ROOT}" "$@"
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
  *)
    makevn_die "Unknown command: ${COMMAND}"
    ;;
esac
