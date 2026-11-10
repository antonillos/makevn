#!/usr/bin/env bash

cmd_jacoco_inspect() { (
  local repo_root="$1" base executable temporary flags props coverage coverage_cli flag expect_define=false rc=0
  local -a arguments=() cli_flags=() prop_flags=() coverage_flags=() coverage_cli_flags=() skip_flags=()
  [[ $# -eq 1 ]] || makevn_die "jacoco-inspect does not accept extra arguments"
  base="$(makevn_detect_maven_base_path "${repo_root}")" || return $?
  executable="$(makevn_maven_executable "${repo_root}" "${base}")" || return $?
  flags="$(makevn_maven_cli_flags_for_command "${repo_root}" verify)"
  props="$(makevn_maven_prop_flags_for_command "${repo_root}" verify)"
  coverage="$(makevn_coverage_prop_flags "${repo_root}")"
  coverage_cli="$(makevn_coverage_cli_flags "${repo_root}")"
  [[ -z "${flags}" ]] || read -r -a cli_flags <<< "${flags}"
  [[ -z "${props}" ]] || read -r -a prop_flags <<< "${props}"
  [[ -z "${coverage}" ]] || read -r -a coverage_flags <<< "${coverage}"
  [[ -z "${coverage_cli}" ]] || read -r -a coverage_cli_flags <<< "${coverage_cli}"
  for flag in ${cli_flags[@]+"${cli_flags[@]}"} ${coverage_cli_flags[@]+"${coverage_cli_flags[@]}"} ${prop_flags[@]+"${prop_flags[@]}"} ${coverage_flags[@]+"${coverage_flags[@]}"}; do
    if [[ "${expect_define}" == true ]]; then
      case "${flag}" in jacoco.skip|jacoco.skip=*) skip_flags+=("-D${flag}") ;; esac
      expect_define=false
    else
      case "${flag}" in
        -D|--define) expect_define=true ;;
        -Djacoco.skip|-Djacoco.skip=*) skip_flags+=("${flag}") ;;
        --define=jacoco.skip|--define=jacoco.skip=*) skip_flags+=("-D${flag#--define=}") ;;
      esac
    fi
  done
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/makevn-jacoco-model.XXXXXXXX")" || return $?
  trap 'rm -rf "${temporary}"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  arguments=("${executable}" ${cli_flags[@]+"${cli_flags[@]}"} ${coverage_cli_flags[@]+"${coverage_cli_flags[@]}"} -nsu -f "${base}/pom.xml"
    org.apache.maven.plugins:maven-help-plugin:3.5.1:effective-pom
    ${prop_flags[@]+"${prop_flags[@]}"} ${coverage_flags[@]+"${coverage_flags[@]}"}
    "-Doutput=${temporary}/effective-pom.xml")
  if MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${base}" jacoco-inspect jacoco-inspect jacoco-inspect "${arguments[@]}"; then
    python3 "${SCRIPT_DIR}/common/jacoco_effective.py" "${temporary}/effective-pom.xml" ${skip_flags[@]+"${skip_flags[@]}"}
  else
    rc=$?
    printf '%s\n' 'JaCoCo model: unknown (effective model could not be generated)' >&2
    return "${rc}"
  fi
)
}
