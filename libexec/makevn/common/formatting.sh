#!/usr/bin/env bash

makevn_hint_format_failure() {
  local log_file="$2"
  [[ -f "${log_file}" ]] || return 0
  grep -qiE '(AJF (validate|verify):|has not been previously formatted|not sorted|format.*(failed|violat|not compliant)|spotless.*(violation|failed|not clean)|Failed to execute goal .*spotless.*:check|Run .*format.*(apply|format))' "${log_file}" || return 0
  printf '\n%s\n' 'Hint: formatting validation failed, not a test assertion. Run:' >&2
  printf '%s\n' '  makevn format --apply' >&2
  printf '%s\n' 'MCP suggestion: makevn_format with apply: true.' >&2
  printf '%s\n' 'Do not add formatter skip flags or edit .mvn/maven.config/.makevn/config to bypass validation. Rerun the original test after formatting.' >&2
}
