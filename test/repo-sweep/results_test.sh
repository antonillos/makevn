#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/results.sh"

[[ "$(extract_exit_code $'[fail] exit 1 | Could not resolve code JDK\n{"exitCode": 1, "durationMs": 12, "tool": "checkstyle", "logPaths": []}')" == 1 ]]
[[ "$(extract_exit_code $'success\n{"exitCode": 0}\nstderr diagnostic')" == 0 ]]
[[ "$(extract_exit_code 'command failed with exit code 2')" == 2 ]]
for invalid in '' 'no status' '{"exitCode": "0"}' '{"exitCode": null}' '{"exitCode": true}'; do
  if extract_exit_code "${invalid}" >/dev/null; then
    printf 'Unexpected success for invalid MCP status: %s\n' "${invalid}" >&2
    exit 1
  fi
done
printf 'Repo-sweep exit status tests passed\n'
