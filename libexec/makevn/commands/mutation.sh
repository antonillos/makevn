#!/usr/bin/env bash
set -euo pipefail

makevn_mutation_goal_for_project() {
  local repo_root="$1"
  local maven_base_path="$2"
  local detected_goal=""

  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_MUTATION_GOAL:-}" ]]; then
    printf '%s\n' "${MAKEVN_MUTATION_GOAL}"
    return 0
  fi

  detected_goal="$(makevn_detect_pit_goal "${maven_base_path}" || true)"
  if [[ -n "${detected_goal}" ]]; then
    printf '%s\n' "${detected_goal}"
    return 0
  fi

  printf '%s\n' "pitest:mutationCoverage"
}

cmd_mutation() {
  local repo_root="$1"
  local module=""
  local verbose=false
  local maven_base_path=""
  local maven_executable=""
  local mutation_goal=""
  local maven_cli_flags_value=""
  local java_home=""
  local logs_dir=""
  local logfile=""
  local relative_log_path=""
  local exit_code=0
  local start_epoch=0
  local end_epoch=0
  local duration_seconds=0
  local duration_display=""
  local -a maven_cli_flags
  local -a maven_args
  local -a extra_args

  shift
  maven_cli_flags=()
  maven_args=()
  extra_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --module)
        [[ $# -ge 2 ]] || makevn_die "Missing value for --module"
        module="$2"
        shift 2
        ;;
      --verbose)
        verbose=true
        shift
        ;;
      --)
        shift
        extra_args=("$@")
        break
        ;;
      *)
        makevn_die "Unknown mutation option: $1"
        ;;
    esac
  done

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${maven_base_path}" ]] || makevn_die "No Maven project detected in ${repo_root}"

  if ! makevn_repo_declares_pit_plugin "${maven_base_path}"; then
    makevn_die "PIT mutation testing plugin (pitest-maven) not detected in pom.xml. Add it to enable mutation testing."
  fi

  mutation_goal="$(makevn_mutation_goal_for_project "${repo_root}" "${maven_base_path}")"
  maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
  maven_cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" mutation)"
  if [[ -n "${maven_cli_flags_value}" ]]; then
    read -r -a maven_cli_flags <<< "${maven_cli_flags_value}"
  fi

  printf '%s\n' "$(makevn_warn "WARNING: Mutation testing (PIT) is VERY slow. This can take 30+ minutes depending on project size.")"
  printf '%s\n' "$(makevn_dim "PIT runs the full test suite multiple times against generated mutants.")"

  maven_args=("${maven_executable}" -q)
  if [[ "${verbose}" == true ]]; then
    maven_args=("${maven_executable}")
  fi
  if [[ ${#maven_cli_flags[@]} -gt 0 ]]; then
    maven_args+=("${maven_cli_flags[@]}")
  fi
  maven_args+=(-f "${maven_base_path}/pom.xml")
  if [[ -n "${module}" ]]; then
    maven_args+=(-pl "${module}")
  fi
  maven_args+=(verify "${mutation_goal}")
  maven_args+=(-DskipITs -Dskip.integration.tests=true)
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    maven_args+=("${extra_args[@]}")
  fi

  java_home="$(makevn_effective_java_home "${repo_root}" code "${maven_base_path}" || true)"
  [[ -n "${java_home}" ]] || makevn_die "Could not resolve code JDK."

  logs_dir="$(makevn_logs_dir "${repo_root}")"
  mkdir -p "${logs_dir}"
  logfile="${logs_dir}/mutation.log"
  : > "${logfile}" 2>/dev/null || true
  relative_log_path=".makevn/logs/mutation.log"
  start_epoch="$(date +%s)"

  makevn_write_backend_metadata \
    "${MAKEVN_BACKEND_METADATA_OUT:-}" \
    "mutation" \
    "${repo_root}" \
    "${repo_root}" \
    "${logfile}" \
    "${relative_log_path}" \
    "$(makevn_quote_command "${maven_args[@]}")" \
    "code" \
    "mutation"

  set +e
  if [[ "${verbose}" == true ]]; then
    (
      cd "${repo_root}"
      env JAVA_HOME="${java_home}" PATH="${java_home}/bin:${PATH}" "${maven_args[@]}"
    ) > "${logfile}" 2>&1
    exit_code=$?
  else
    (
      cd "${repo_root}"
      env JAVA_HOME="${java_home}" PATH="${java_home}/bin:${PATH}" "${maven_args[@]}"
    ) 2>&1 >/dev/null | grep -v 'PIT >> FINE' > "${logfile}"
    exit_code=${PIPESTATUS[0]}
  fi
  set -e

  end_epoch="$(date +%s)"
  duration_seconds=$((end_epoch - start_epoch))
  duration_display="$(makevn_format_duration "${duration_seconds}")"

  if [[ ${exit_code} -eq 0 ]]; then
    printf '%s %s\n' "$(makevn_accent '[ok]')" "$(makevn_accent "${duration_display}")"
  else
    printf '%s\n' "$(makevn_warn "fail exit ${exit_code} after ${duration_display}")"
  fi

  printf '\n%s\n' "$(makevn_dim "Mutation report: \${module}/target/pit-reports/index.html")"
  printf '%s\n' "$(makevn_dim "Error log: ${relative_log_path}")"
  printf '%s\n' "$(makevn_accent "Mutation COMPLETED")"

  return ${exit_code}
}
