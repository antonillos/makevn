#!/usr/bin/env bash
# Source inside VHS Bash: a failed command must not look like a successful demo.
# These are human-facing terminals, not the agent environment launching VHS.
# NO_COLOR must be absent (even an empty value disables Rust frontend colors).
unset NO_COLOR MAKEVN_AGENT_OUTPUT MAKEVN_COMPACT_OUTPUT
export TERM=xterm-256color COLORTERM=truecolor

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
