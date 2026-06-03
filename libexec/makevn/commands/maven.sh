#!/usr/bin/env bash
set -euo pipefail

makevn_reject_verify_skip_flags() {
  local command_name="$1"
  local arg=""

  shift

  for arg in "$@"; do
    case "${command_name}:${arg}" in
      verify:-DskipUTs|verify:-DskipUTs=*|verify:-DskipITs|verify:-DskipITs=*|verify:-Dskip.unit.tests=true|verify:-Dskip.unit.tests=false)
        makevn_die "verify does not accept UT/IT skip flags; use verify-ut or verify-it instead"
        ;;
      verify-ut:-DskipUTs|verify-ut:-DskipUTs=*|verify-ut:-Dskip.unit.tests=true|verify-ut:-Dskip.unit.tests=false)
        makevn_die "verify-ut must not skip unit tests"
        ;;
      verify-it:-DskipIT|verify-it:-DskipIT=*|verify-it:-DskipITs|verify-it:-DskipITs=*|verify-it:-DskipITests|verify-it:-DskipITests=*|verify-it:-DskipIntegrationTests|verify-it:-DskipIntegrationTests=*|verify-it:-DskipFailsafeTests|verify-it:-DskipFailsafeTests=*|verify-it:-Dmaven.failsafe.skip|verify-it:-Dmaven.failsafe.skip=*)
        makevn_die "verify-it must not skip integration tests"
        ;;
    esac
  done
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
  makevn_run_maven_goal "${repo_root}" package package build -DskipTests -Dmaven.build.cache.enabled=false "$@"
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
  local cli_flags_value=""
  local coverage_prop_flags_value=""
  local -a cli_flags=()
  local -a coverage_prop_flags=()

  shift
  [[ "${1:-}" == "--" ]] && shift
  makevn_reject_verify_skip_flags verify-ut "$@"
  cli_flags_value="$(makevn_coverage_cli_flags "${repo_root}")"
  if [[ -n "${cli_flags_value}" ]]; then
    read -r -a cli_flags <<< "${cli_flags_value}"
  fi
  coverage_prop_flags_value="$(makevn_coverage_prop_flags "${repo_root}")"
  if [[ -n "${coverage_prop_flags_value}" ]]; then
    read -r -a coverage_prop_flags <<< "${coverage_prop_flags_value}"
  fi
  if [[ ${#cli_flags[@]} -gt 0 ]]; then
    makevn_run_maven_goal "${repo_root}" verify verify-ut "" \
      "${cli_flags[@]}" \
      "${coverage_prop_flags[@]}" \
      -DskipITs \
      -DfailIfNoTests=false \
      -Dmaven.test.failure.ignore=false \
      "$@"
  else
    makevn_run_maven_goal "${repo_root}" verify verify-ut "" \
      "${coverage_prop_flags[@]}" \
      -DskipITs \
      -DfailIfNoTests=false \
      -Dmaven.test.failure.ignore=false \
      "$@"
  fi
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
  makevn_reject_verify_skip_flags verify-it "$@"
  if makevn_verify_requires_boot_docker "${repo_root}"; then
    cmd_docker_ps_required "${repo_root}"
  fi
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
  local local_containers=""
  shift
  [[ "${1:-}" == "--" ]] && shift
  makevn_reject_verify_skip_flags verify "$@"
  if makevn_verify_requires_boot_docker "${repo_root}"; then
    cmd_docker_ps_required "${repo_root}"
  fi
  makevn_load_profile "${repo_root}"
  local_containers="$(makevn_effective_local_containers "${repo_root}" "${MAKEVN_PROFILE_VERIFY_IT_LOCAL_CONTAINERS:-}")"
  if [[ -n "${local_containers}" ]]; then
    LOCAL_CONTAINERS="${local_containers}" makevn_run_maven_goal "${repo_root}" verify verify verify -Dmaven.build.cache.enabled=false "$@"
  else
    makevn_run_maven_goal "${repo_root}" verify verify verify -Dmaven.build.cache.enabled=false "$@"
  fi
}

cmd_pr_verify() {
  local repo_root="$1"
  local maven_base_path=""
  local maven_executable=""
  local cli_flags_value=""
  local rc=0
  local -a cli_flags=()
  local -a coverage_prop_flags=()
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
  maven_args+=(-f "${maven_base_path}/pom.xml" clean verify)
  read -r -a coverage_prop_flags <<< "$(makevn_coverage_prop_flags "${repo_root}")"
  if [[ ${#coverage_prop_flags[@]} -gt 0 ]]; then
    maven_args+=("${coverage_prop_flags[@]}")
  fi
  maven_args+=(-DskipITs -DfailIfNoTests=false -Dmaven.test.failure.ignore=false -Dmaven.build.cache.enabled=false)
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    maven_args+=("${extra_args[@]}")
  fi

  MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" pr-verify pr-verify pr-verify "${maven_args[@]}"
  rc=$?
  [[ ${rc} -eq 0 ]] && makevn_print_jacoco_report_hint "${maven_base_path}"
  return ${rc}
}

cmd_format() {
  local repo_root="$1"
  local apply=false
  local maven_base_path=""
  local goal=""
  local -a extra_args

  shift
  extra_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)
        apply=true
        shift
        ;;
      --)
        shift
        extra_args=("$@")
        break
        ;;
      *)
        makevn_die "Unknown format option: $1"
        ;;
    esac
  done

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${maven_base_path}" ]] || makevn_die "No Maven project detected in ${repo_root}"
  goal="$(makevn_format_goal_for_project "${repo_root}" "${maven_base_path}" "${apply}")"

  if [[ ${#extra_args[@]} -gt 0 ]]; then
    makevn_run_maven_goal "${repo_root}" "${goal}" format format "${extra_args[@]}"
  else
    makevn_run_maven_goal "${repo_root}" "${goal}" format format
  fi
}

makevn_format_goal_for_project() {
  local repo_root="$1"
  local maven_base_path="$2"
  local apply="$3"
  local detected_goal=""

  makevn_load_config "${repo_root}"
  if [[ "${apply}" == true && -n "${MAKEVN_FORMAT_APPLY_GOAL:-}" ]]; then
    printf '%s\n' "${MAKEVN_FORMAT_APPLY_GOAL}"
    return 0
  fi
  if [[ "${apply}" != true && -n "${MAKEVN_FORMAT_CHECK_GOAL:-}" ]]; then
    printf '%s\n' "${MAKEVN_FORMAT_CHECK_GOAL}"
    return 0
  fi

  detected_goal="$(makevn_detect_format_plugin_goal "${maven_base_path}" "${apply}" || true)"
  if [[ -n "${detected_goal}" ]]; then
    printf '%s\n' "${detected_goal}"
    return 0
  fi

  makevn_die "No formatting plugin configured for this Maven project. Add MAKEVN_FORMAT_CHECK_GOAL and MAKEVN_FORMAT_APPLY_GOAL to .makevn/config, or declare a supported formatter plugin in pom.xml."
}

makevn_detect_format_plugin_goal() {
  local maven_base_path="$1"
  local apply="$2"
  local pom_path=""
  local detected_goal=""

  while IFS= read -r pom_path; do
    [[ -f "${pom_path}" ]] || continue
    detected_goal="$(MAKEVN_FORMAT_APPLY="${apply}" perl -0ne '
      my $apply = $ENV{"MAKEVN_FORMAT_APPLY"} || "false";

      sub tag_value {
        my ($xml, $tag) = @_;
        return $1 if $xml =~ m{<$tag(?:\s[^>]*)?>\s*([^<]+?)\s*</$tag>}s;
        return "";
      }

      sub has_goal {
        my ($xml, $goal) = @_;
        return $xml =~ m{<goal(?:\s[^>]*)?>\s*\Q$goal\E\s*</goal>}s;
      }

      while (m{<plugin(?:\s[^>]*)?>.*?</plugin>}sg) {
        my $plugin = $&;
        my $group_id = tag_value($plugin, "groupId");
        my $artifact_id = tag_value($plugin, "artifactId");
        next unless $artifact_id;

        if ($artifact_id eq "spotless-maven-plugin") {
          print $apply eq "true" ? "spotless:apply\n" : "spotless:check\n";
          exit 0;
        }
        if ($artifact_id eq "fmt-maven-plugin") {
          print $apply eq "true" ? "fmt:format\n" : "fmt:check\n";
          exit 0;
        }
        if ($artifact_id eq "formatter-maven-plugin") {
          print $apply eq "true" ? "formatter:format\n" : "formatter:validate\n";
          exit 0;
        }

        my $looks_like_formatter =
          $artifact_id =~ /(?:^|[-_.])(?:java)?format(?:ter)?(?:[-_.]|$)/i ||
          $plugin =~ m{<googleJavaFormat(?:\s|/|>)}s;
        next unless $looks_like_formatter && $group_id;

        my $goal = "";
        if ($apply eq "true") {
          $goal = has_goal($plugin, "apply") ? "apply" : has_goal($plugin, "format") ? "format" : "apply";
        } else {
          $goal = has_goal($plugin, "validate") ? "validate" : has_goal($plugin, "check") ? "check" : "validate";
        }

        print "$group_id:$artifact_id:$goal\n";
        exit 0;
      }
    ' "${pom_path}")"
    if [[ -n "${detected_goal}" ]]; then
      printf '%s\n' "${detected_goal}"
      return 0
    fi
  done < <(
    if [[ -f "${maven_base_path}/pom.xml" ]]; then
      printf '%s\n' "${maven_base_path}/pom.xml"
    fi
    find "${maven_base_path}" \
      \( -path '*/target/*' -o -path '*/node_modules/*' -o -path "${maven_base_path}/pom.xml" \) -prune \
      -o -name pom.xml -type f -print 2>/dev/null | LC_ALL=C sort
  )
}

cmd_checkstyle() {
  local repo_root="$1"
  local module=""
  local verbose=false
  local maven_base_path=""
  local maven_base_rel=""
  local maven_executable=""
  local checkstyle_goal=""
  local maven_cli_flags_value=""
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
        makevn_die "Unknown checkstyle option: $1"
        ;;
    esac
  done

  maven_base_path="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${maven_base_path}" ]] || makevn_die "No Maven project detected in ${repo_root}"
  if [[ -n "${module}" && ! -f "${repo_root}/pom.xml" ]]; then
    maven_base_rel="${maven_base_path#${repo_root}/}"
    if [[ "${module}" == "${maven_base_rel}" || "${module}" == "$(basename "${maven_base_path}")" ]]; then
      module=""
    fi
  fi
  checkstyle_goal="$(makevn_checkstyle_goal_for_project "${repo_root}" "${maven_base_path}")"
  maven_executable="$(makevn_maven_executable "${repo_root}" "${maven_base_path}")"
  maven_cli_flags_value="$(makevn_maven_cli_flags_for_command "${repo_root}" checkstyle)"
  if [[ -n "${maven_cli_flags_value}" ]]; then
    read -r -a maven_cli_flags <<< "${maven_cli_flags_value}"
  fi

  maven_args=("${maven_executable}")
  if [[ ${#maven_cli_flags[@]} -gt 0 ]]; then
    maven_args+=("${maven_cli_flags[@]}")
  fi
  if [[ "${verbose}" != true ]]; then
    maven_args+=("-q")
  fi
  maven_args+=(-f "${maven_base_path}/pom.xml")
  if [[ -n "${module}" ]]; then
    maven_args+=(-pl "${module}")
  fi
  maven_args+=("${checkstyle_goal}")
  if [[ "${verbose}" == true ]]; then
    maven_args+=(-Dcheckstyle.consoleOutput=true)
  fi
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    maven_args+=("${extra_args[@]}")
  fi

  MAKEVN_COMPACT_OUTPUT=1 makevn_run_logged_in_context "${repo_root}" code "${maven_base_path}" checkstyle checkstyle checkstyle "${maven_args[@]}"
}

makevn_checkstyle_goal_for_project() {
  local repo_root="$1"
  local maven_base_path="$2"
  local detected_goal=""

  makevn_load_config "${repo_root}"
  if [[ -n "${MAKEVN_CHECKSTYLE_GOAL:-}" ]]; then
    printf '%s\n' "${MAKEVN_CHECKSTYLE_GOAL}"
    return 0
  fi

  detected_goal="$(makevn_detect_checkstyle_plugin_goal "${maven_base_path}" || true)"
  if [[ -n "${detected_goal}" ]]; then
    printf '%s\n' "${detected_goal}"
    return 0
  fi
  detected_goal="$(makevn_detect_format_plugin_goal "${maven_base_path}" false || true)"
  if [[ -n "${detected_goal}" ]]; then
    printf '%s\n' "${detected_goal}"
    return 0
  fi

  makevn_die "No Checkstyle plugin configured for this Maven project. Add MAKEVN_CHECKSTYLE_GOAL to .makevn/config, or declare maven-checkstyle-plugin or a formatter validation plugin in pom.xml."
}

makevn_detect_checkstyle_plugin_goal() {
  local maven_base_path="$1"
  local pom_path=""
  local detected_goal=""

  while IFS= read -r pom_path; do
    [[ -f "${pom_path}" ]] || continue
    detected_goal="$(perl -0ne '
      sub tag_value {
        my ($xml, $tag) = @_;
        return $1 if $xml =~ m{<$tag(?:\s[^>]*)?>\s*([^<]+?)\s*</$tag>}s;
        return "";
      }

      while (m{<plugin(?:\s[^>]*)?>.*?</plugin>}sg) {
        my $plugin = $&;
        my $group_id = tag_value($plugin, "groupId");
        my $artifact_id = tag_value($plugin, "artifactId");
        next unless $artifact_id eq "maven-checkstyle-plugin";

        if ($group_id && $group_id ne "org.apache.maven.plugins") {
          print "$group_id:$artifact_id:check\n";
        } else {
          print "org.apache.maven.plugins:maven-checkstyle-plugin:check\n";
        }
        exit 0;
      }
    ' "${pom_path}")"
    if [[ -n "${detected_goal}" ]]; then
      printf '%s\n' "${detected_goal}"
      return 0
    fi
  done < <(
    if [[ -f "${maven_base_path}/pom.xml" ]]; then
      printf '%s\n' "${maven_base_path}/pom.xml"
    fi
    find "${maven_base_path}" \
      \( -path '*/target/*' -o -path '*/node_modules/*' -o -path "${maven_base_path}/pom.xml" \) -prune \
      -o -name pom.xml -type f -print 2>/dev/null | LC_ALL=C sort
  )
}
