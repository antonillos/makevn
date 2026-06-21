#!/usr/bin/env bash
set -euo pipefail

cmd_exec() {
  local repo_root="$1"
  local context="code"
  local delegated_command=""
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
  delegated_command="$1"
  case "${delegated_command}" in
    mvn|mvnw|./mvnw|java|./*)
      ;;
    *)
      makevn_die "makevn exec only supports Maven, Java, or repo-local executable commands; use native shell tools for ${delegated_command}"
      ;;
  esac
  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  print_command_intro "${repo_root}" "exec --context ${context}"
  makevn_run_in_context "${repo_root}" "${context}" "${maven_base_path}" "$@"
}
