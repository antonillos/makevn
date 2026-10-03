#!/usr/bin/env bash

makevn_hint_format_failure() {
  local repo_root="$1" log_file="$2"
  [[ -f "${log_file}" ]] || return 0
  grep -qiE '(AJF (validate|verify): AJF .*failed|Failed to execute goal [^ ]*(spotless-maven-plugin|amiga-javaformat-maven-plugin|fmt-maven-plugin|formatter-maven-plugin|spring-javaformat-maven-plugin):[^ ]*(check|validate)|^\[ERROR\].*The following files had format violations)' "${log_file}" || makevn_log_has_project_formatter_failure "${repo_root}" "${log_file}" || return 0
  printf '\n%s\n' 'Hint: formatting validation failed, not a test assertion. Run:' >&2
  printf '%s\n' '  makevn format --apply' >&2
  printf '%s\n' 'MCP suggestion: makevn_format with apply: true.' >&2
  printf '%s\n' 'Do not add formatter skip flags or edit .mvn/maven.config/.makevn/config to bypass validation. Rerun the original test without --fast after formatting so changed sources are recompiled.' >&2
}


makevn_log_has_project_formatter_failure() {
  local repo_root="$1" log_file="$2" base="" goal=""
  base="$(makevn_detect_maven_base_path "${repo_root}" || true)"
  [[ -n "${base}" ]] || return 1
  goal="$(makevn_format_goal_for_project "${repo_root}" "${base}" false 2>/dev/null || true)"
  [[ -n "${goal}" ]] || return 1
  MAKEVN_RECOVERY_GOALS="${goal}" perl -ne '
    BEGIN { @goals = split /\s+/, $ENV{MAKEVN_RECOVERY_GOALS}; }
    next unless /Failed to execute goal ([^\s]+)/;
    my @failed = split /:/, $1;
    for my $goal (@goals) {
      my @expected = split /:/, $goal;
      next unless @expected >= 2 && @failed >= 2;
      next unless $expected[-1] eq $failed[-1];
      if (@expected >= 3) {
        next unless @failed >= 3 && $expected[0] eq $failed[0] && $expected[1] eq $failed[1];
      } else {
        # Maven expands conventional plugin prefixes in failure diagnostics.
        next unless $failed[0] eq $expected[0] ||
          (@failed >= 3 && ($failed[1] eq "$expected[0]-maven-plugin" ||
                           $failed[1] eq "maven-$expected[0]-plugin"));
      }
      $matched = 1;
      last;
    }
    END { exit($matched ? 0 : 1); }
  ' "${log_file}"
}
