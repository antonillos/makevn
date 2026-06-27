#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

CLI_SCRIPT="${SCRIPT_DIR}/cli.sh"

backend_usage() {
  printf 'Usage: backend.sh BACKEND_COMMAND --repo ABS_PATH [BACKEND_OPTIONS...] [-- EXTRA_ARGS...]\n' >&2
}

backend_require_value() {
  local flag="$1"
  local value="${2:-}"

  [[ -n "${value}" ]] || makevn_die "Missing value for ${flag}"
}

COMMAND="${1:-}"
[[ -n "${COMMAND}" ]] || {
  backend_usage
  exit 1
}
shift

REPO_ROOT=""
FORMAT=""
METADATA_OUT=""
COMPACT_OUTPUT=false
FORWARD_ARGS=()
CLI_ARGS=("--repo")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      backend_require_value "--repo" "${2:-}"
      REPO_ROOT="$2"
      shift 2
      ;;
    --format)
      backend_require_value "--format" "${2:-}"
      FORMAT="$2"
      shift 2
      ;;
    --metadata-out)
      backend_require_value "--metadata-out" "${2:-}"
      METADATA_OUT="$2"
      shift 2
      ;;
    --compact)
      COMPACT_OUTPUT=true
      shift
      ;;
    --)
      FORWARD_ARGS+=("--")
      shift
      FORWARD_ARGS+=("$@")
      break
      ;;
    *)
      FORWARD_ARGS+=("$1")
      shift
      ;;
  esac
done

[[ -n "${REPO_ROOT}" ]] || makevn_die "Missing required --repo"
[[ "${REPO_ROOT}" = /* ]] || makevn_die "Backend --repo must be an absolute path: ${REPO_ROOT}"
[[ -f "${CLI_SCRIPT}" ]] || makevn_die "Backend runtime not found at ${CLI_SCRIPT}"
[[ -z "${METADATA_OUT}" || "${METADATA_OUT}" = /* ]] || makevn_die "Backend --metadata-out must be an absolute path: ${METADATA_OUT}"

case "${COMMAND}" in
  doctor|init|refresh|make|uninstall|profile|exec|compile|test-compile|compile-tests|validate|package|build|clean|test|verify-ut|verify-ut-coverage|verify-it|verify-it-coverage|verify|verify-changes-preview|verify-changes|coverage|coverage-changes|pr-verify|format|checkstyle|docker-up|docker-down|docker-ps|docker-stats|docker-ps-required|karate-docker-up|karate-docker-down|karate-test|karate-all|run-app|run-app-bg|stop-app|run|jdk|mutation)
    ;;
  *)
    makevn_die "Unknown backend command: ${COMMAND}"
    ;;
esac

case "${COMMAND}" in
  doctor|init|refresh|make|uninstall|profile|run-app-bg|stop-app|jdk)
    if [[ "${COMMAND}" == "doctor" ]]; then
      if [[ -n "${FORMAT}" && "${FORMAT}" != "text" && "${FORMAT}" != "json" ]]; then
        makevn_die "Backend format not implemented yet for ${COMMAND}: ${FORMAT}"
      fi
    elif [[ -n "${FORMAT}" && "${FORMAT}" != "text" ]]; then
      makevn_die "Backend format not implemented yet for ${COMMAND}: ${FORMAT}"
    fi
    [[ -z "${METADATA_OUT}" ]] || makevn_die "Backend metadata output is not valid for state command: ${COMMAND}"
    ;;
  *)
    [[ -z "${FORMAT}" ]] || makevn_die "Backend format is not valid for run command: ${COMMAND}"
    ;;
esac

if [[ -n "${METADATA_OUT}" ]]; then
  export MAKEVN_BACKEND_METADATA_OUT="${METADATA_OUT}"
  export MAKEVN_BACKEND_REPO_ROOT="${REPO_ROOT}"
  export MAKEVN_BACKEND_COMMAND="${COMMAND}"
  export MAKEVN_BACKEND_COMMAND_DISPLAY="makevn ${COMMAND}"
else
  unset MAKEVN_BACKEND_METADATA_OUT || true
  unset MAKEVN_BACKEND_REPO_ROOT || true
  unset MAKEVN_BACKEND_COMMAND || true
  unset MAKEVN_BACKEND_COMMAND_DISPLAY || true
fi

if [[ "${COMPACT_OUTPUT}" == "true" ]]; then
  export MAKEVN_COMPACT_OUTPUT=1
  export NO_COLOR=1
fi

if [[ "${COMMAND}" == "doctor" && "${FORMAT:-text}" == "json" ]]; then
  makevn_collect_doctor_snapshot "${REPO_ROOT}"
  makevn_print_doctor_json
  exit 0
fi

CLI_ARGS+=("${REPO_ROOT}" "${COMMAND}")
if [[ ${#FORWARD_ARGS[@]} -gt 0 ]]; then
  CLI_ARGS+=("${FORWARD_ARGS[@]}")
fi

exec "${CLI_SCRIPT}" "${CLI_ARGS[@]}"
