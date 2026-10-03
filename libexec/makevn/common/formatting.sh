#!/usr/bin/env bash

# Never guess a selector for an unknown plugin: ignored properties format all files.
makevn_format_single_file() {
  local repo_root="$1" base="$2" goal="$3" file="$4"
  local resolved="" owner="" pattern=""
  base="$(CDPATH= cd -- "${base}" && pwd -P)"
  resolved="$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0]) // ""' -- "${repo_root}/${file}")"
  [[ "${file}" == /* ]] && resolved="$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0]) // ""' -- "${file}")"
  [[ -f "${resolved}" && "${resolved}" == "${base}/"* ]] || makevn_die "--file must name an existing file inside the Maven project"
  case "${goal}" in
    spotless:apply|spotless:check|com.diffplug.spotless:spotless-maven-plugin:apply|com.diffplug.spotless:spotless-maven-plugin:check) ;;
    *) makevn_die "Single-file formatting is not supported for ${goal}; use makevn format --apply. Do not disable formatting checks." ;;
  esac
  owner="$(dirname "${resolved}")"
  while [[ ! -f "${owner}/pom.xml" ]]; do owner="$(dirname "${owner}")"; done
  pattern="$(perl -e 'print quotemeta($ARGV[0])' -- "${resolved}")"
  makevn_run_maven_goal "${repo_root}" "${goal}" format format -f "${owner}/pom.xml" -N "-DspotlessFiles=^${pattern}$"
}

makevn_hint_format_failure() {
  local repo_root="$1" log_file="$2" file="" base="" goal=""
  [[ -f "${log_file}" ]] || return 0
  grep -qiE '(format.*(failed|violat|not compliant)|not sorted|spotless.*(check|violation)|Run .*format.*(apply|format))' "${log_file}" || return 0
  printf '\n%s\n' 'Hint: formatting validation failed, not a test assertion. Run:' >&2
  file="$(perl -ne 'if (/The file (.+?) is not sorted/) { print $1; exit }' "${log_file}")"
  base="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${base}" ]] && goal="$(makevn_detect_format_plugin_goal "${base}" true || true)"
  case "${goal}" in
    spotless:apply|com.diffplug.spotless:spotless-maven-plugin:apply)
      if [[ -n "${file}" ]]; then
        printf '  makevn format --apply --file %q\n' "${file}" >&2
      else
        printf '  makevn format --apply\n' >&2
      fi
      ;;
    *) printf '  makevn format --apply\n' >&2 ;;
  esac
  printf '%s\n' 'For a supported single-file formatter: makevn format --apply --file PATH' >&2
  printf '%s\n' 'Do not add formatter skip flags or edit .mvn/maven.config/.makevn/config to bypass validation. Rerun the original test after formatting.' >&2
}
