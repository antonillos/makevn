#!/usr/bin/env bash
# Source inside VHS Bash: a failed command must not look like a successful demo.
makevn_demo_prompt() {
  local status=$?
  if (( status != 0 )); then
    printf 'Demo failed (exit %s); recording rejected.\n' "$status" >&2
    exit "$status"
  fi
  PS1='demo> '
}
PROMPT_COMMAND=makevn_demo_prompt
PS1='demo> '
