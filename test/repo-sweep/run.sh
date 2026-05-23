#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_TARGET_ROOT="/Users/antonio.saco/Projects/github"
DEFAULT_TMP_BASE="/var/folders/j6/tmmvrpxn7lbgddz74sh6bwlr4v_klg/T/opencode"
TARGET_ROOT="${1:-${MAKEVN_REPO_SWEEP_ROOT:-${DEFAULT_TARGET_ROOT}}}"
TMP_BASE="${MAKEVN_REPO_SWEEP_TMP_BASE:-${DEFAULT_TMP_BASE}}"
TMP_ROOT="$(mktemp -d "${TMP_BASE%/}/makevn-repo-sweep.XXXXXX")"
REPORT_DIR="${TMP_ROOT}/report"
RESULTS_TSV="${REPORT_DIR}/results.tsv"
SUMMARY_MD="${REPORT_DIR}/summary.md"
TOOLS_JSON="${REPORT_DIR}/tools.json"
LOG_PREFIX="${REPORT_DIR}/log"
COMMAND_TIMEOUT_SECONDS="${MAKEVN_REPO_SWEEP_TIMEOUT_SECONDS:-45}"

MAKEVN_BIN="${MAKEVN_BIN:-${ROOT_DIR}/target/release/makevn}"
MCP_BIN="${MCP_BIN:-${ROOT_DIR}/target/release/makevn-mcp}"
INSTALL_PREFIX="${TMP_ROOT}/install-prefix"
INSTALL_BIN_DIR="${INSTALL_PREFIX}/bin"

mkdir -p "${REPORT_DIR}"
printf 'repo\tworkspace\tcommand\tstatus\tnote\n' > "${RESULTS_TSV}"

resolve_bin() {
  local candidate="$1"
  local fallback="$2"

  if [[ -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  command -v "${fallback}"
}

if [[ -x "${ROOT_DIR}/target/release/makevn" && -x "${ROOT_DIR}/target/release/makevn-mcp" ]]; then
  PREFIX="${INSTALL_PREFIX}" "${ROOT_DIR}/install.sh" >/dev/null
  MAKEVN_BIN="${INSTALL_BIN_DIR}/makevn"
  MCP_BIN="${INSTALL_BIN_DIR}/makevn-mcp"
else
  MAKEVN_BIN="$(resolve_bin "${MAKEVN_BIN}" makevn)"
  MCP_BIN="$(resolve_bin "${MCP_BIN}" makevn-mcp)"
fi

log() {
  printf '[repo-sweep] %s\n' "$*"
}

record() {
  local repo_name="$1"
  local workspace="$2"
  local command_name="$3"
  local status="$4"
  local note="$5"

  note="${note//$'\n'/ | }"
  note="${note//$'\t'/ }"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${repo_name}" \
    "${workspace}" \
    "${command_name}" \
    "${status}" \
    "${note}" >> "${RESULTS_TSV}"
}

extract_exit_code() {
  local output="$1"

  if [[ "${output}" =~ exit[[:space:]]code[[:space:]](-?[0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  printf '0\n'
}

summarize_output() {
  local output="$1"
  local first_line=""

  first_line="${output%%$'\n'*}"
  first_line="${first_line#:: }"
  first_line="${first_line#│ }"

  if [[ -z "${first_line}" ]]; then
    first_line="(no output)"
  fi

  printf '%s\n' "${first_line}"
}

mcp_call() {
  local repo_path="$1"
  local tool_name="$2"
  local args_json="$3"

  python3 - "${MCP_BIN}" "${repo_path}" "${tool_name}" "${args_json}" <<'PY'
import json
import subprocess
import sys

mcp_bin, repo_path, tool_name, args_json = sys.argv[1:5]
timeout_seconds = int(__import__('os').environ.get('MAKEVN_REPO_SWEEP_TIMEOUT_SECONDS', '45'))
arguments = json.loads(args_json)
if repo_path:
    arguments.setdefault("repo", repo_path)

request_lines = [
    json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "repo-sweep", "version": "0"},
            },
        }
    ),
    json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": arguments},
        }
    ),
]

proc = subprocess.Popen(
    [mcp_bin],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
try:
    stdout, stderr = proc.communicate("\n".join(request_lines) + "\n", timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    proc.kill()
    stdout, stderr = proc.communicate()
    message = f"timed out after {timeout_seconds}s"
    if stderr.strip():
        message += f" | {stderr.strip()}"
    elif stdout.strip():
        message += f" | {stdout.strip().splitlines()[-1]}"
    sys.stderr.write(message)
    raise SystemExit(124)
if proc.returncode != 0:
    sys.stderr.write((stderr or stdout).strip())
    raise SystemExit(proc.returncode)

responses = [json.loads(line) for line in stdout.splitlines() if line.strip()]
if len(responses) < 2:
    text = stderr.strip() or stdout.strip() or "missing MCP response"
    sys.stderr.write(text)
    raise SystemExit(92)

response = responses[-1]
if "error" in response:
    sys.stderr.write(response["error"].get("message", "unknown MCP error"))
    raise SystemExit(93)

content = response.get("result", {}).get("content", [])
text_parts = [part.get("text", "") for part in content if part.get("type") == "text"]
text = "\n".join(part for part in text_parts if part)
if stderr.strip():
    if text:
        text += "\n"
    text += stderr.strip()
sys.stdout.write(text)
PY
}

mcp_list_tools() {
  python3 - "${MCP_BIN}" <<'PY'
import json
import subprocess
import sys

mcp_bin = sys.argv[1]
request_lines = [
    json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "repo-sweep", "version": "0"},
            },
        }
    ),
    json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}),
]
proc = subprocess.Popen(
    [mcp_bin],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
stdout, stderr = proc.communicate("\n".join(request_lines) + "\n")
if proc.returncode != 0:
    sys.stderr.write((stderr or stdout).strip())
    raise SystemExit(proc.returncode)
responses = [json.loads(line) for line in stdout.splitlines() if line.strip()]
if len(responses) < 2:
    sys.stderr.write(stderr.strip() or stdout.strip() or "missing MCP tools/list response")
    raise SystemExit(94)
json.dump(responses[-1].get("result", {}), sys.stdout, indent=2, sort_keys=True)
PY
}

run_tool() {
  local repo_name="$1"
  local workspace="$2"
  local repo_path="$3"
  local command_name="$4"
  local args_json="$5"
  local path_prefix="$6"
  local output=""
  local cmd_status=0
  local exit_code=0
  local status="ok"
  local note=""

  set +e
  output="$(MAKEVN_REPO_SWEEP_TIMEOUT_SECONDS="${COMMAND_TIMEOUT_SECONDS}" PATH="${path_prefix}:${PATH}" mcp_call "${repo_path}" "${command_name}" "${args_json}" 2>&1)"
  cmd_status=$?
  set -e

  if [[ ${cmd_status} -ne 0 ]]; then
    if [[ ${cmd_status} -eq 124 ]]; then
      status="timeout"
    else
      status="transport_fail"
    fi
    note="$(summarize_output "${output}")"
    record "${repo_name}" "${workspace}" "${command_name}" "${status}" "${note}"
    return 1
  fi

  exit_code="$(extract_exit_code "${output}")"
  note="$(summarize_output "${output}")"
  if [[ "${exit_code}" != "0" ]]; then
    status="fail"
  fi

  record "${repo_name}" "${workspace}" "${command_name}" "${status}" "${note}"

  if [[ "${status}" == "ok" ]]; then
    return 0
  fi

  return 1
}

run_make_check() {
  local repo_name="$1"
  local repo_path="$2"
  local command_name="$3"

  if [[ ! -f "${repo_path}/.makevn/makevn.mk" ]]; then
    record "${repo_name}" clone "${command_name}" skip "missing .makevn/makevn.mk"
    return 0
  fi

  if PATH="${INSTALL_BIN_DIR}:${PATH}" make -f "${repo_path}/.makevn/makevn.mk" -C "${repo_path}" MAKEVN_BIN="${MAKEVN_BIN}" vn-doctor >/dev/null 2>&1; then
    record "${repo_name}" clone "${command_name}" ok "vn-doctor succeeded"
    return 0
  fi

  record "${repo_name}" clone "${command_name}" fail "vn-doctor failed"
  return 1
}

doctor_has() {
  local output="$1"
  local expected="$2"
  [[ "${output}" == *"${expected}"* ]]
}

setup_fake_docker() {
  local fake_bin="$1"
  local docker_log="$2"

  mkdir -p "${fake_bin}"

  cat > "${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "${MAKEVN_FAKE_DOCKER_LOG:?}"
if [[ "${1:-}" == "stats" ]]; then
  printf 'CONTAINER ID   NAME   CPU %%   MEM USAGE / LIMIT   MEM %%   NET I/O   BLOCK I/O   PIDS\n'
fi
exit 0
EOF

  cat > "${fake_bin}/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker-compose %s\n' "$*" >> "${MAKEVN_FAKE_DOCKER_LOG:?}"
exit 0
EOF

  chmod +x "${fake_bin}/docker" "${fake_bin}/docker-compose"
  : > "${docker_log}"
}

clone_repo() {
  local source_repo="$1"
  local clone_repo="$2"

  git clone --quiet --no-hardlinks --local "${source_repo}" "${clone_repo}" >/dev/null 2>&1
}

workflow_group() {
  local index="$1"
  case $((index % 4)) in
    0) printf 'build_cycle\n' ;;
    1) printf 'test_cycle\n' ;;
    2) printf 'verify_cycle\n' ;;
    3) printf 'coverage_cycle\n' ;;
  esac
}

run_workflow_group() {
  local repo_name="$1"
  local repo_path="$2"
  local path_prefix="$3"
  local group_name="$4"

  case "${group_name}" in
    build_cycle)
      run_tool "${repo_name}" clone "${repo_path}" validate '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" compile '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" package '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" clean '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" build '{}' "${path_prefix}" || true
      ;;
    test_cycle)
      run_tool "${repo_name}" clone "${repo_path}" test_compile '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" compile_tests '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" test '{"fast": true}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" verify_ut '{}' "${path_prefix}" || true
      ;;
    verify_cycle)
      run_tool "${repo_name}" clone "${repo_path}" verify_it '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" verify '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" verify_changes '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" pr_verify '{}' "${path_prefix}" || true
      ;;
    coverage_cycle)
      run_tool "${repo_name}" clone "${repo_path}" clean '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" verify_ut_coverage '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" coverage '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" coverage_changes '{}' "${path_prefix}" || true
      run_tool "${repo_name}" clone "${repo_path}" verify_it_coverage '{}' "${path_prefix}" || true
      ;;
  esac
}

write_summary() {
  python3 - "${RESULTS_TSV}" "${SUMMARY_MD}" <<'PY'
import csv
import pathlib
import sys
from collections import Counter, defaultdict

results_path = pathlib.Path(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])
rows = list(csv.DictReader(results_path.open(), delimiter='\t'))
status_counts = Counter(row['status'] for row in rows)
repo_counts = defaultdict(Counter)
for row in rows:
    repo_counts[row['repo']][row['status']] += 1

lines = []
lines.append('# makevn repo sweep')
lines.append('')
lines.append(f'- total checks: {len(rows)}')
lines.append(f'- ok: {status_counts.get("ok", 0)}')
lines.append(f'- fail: {status_counts.get("fail", 0)}')
lines.append(f'- skip: {status_counts.get("skip", 0)}')
lines.append(f'- timeout: {status_counts.get("timeout", 0)}')
lines.append(f'- transport_fail: {status_counts.get("transport_fail", 0)}')
lines.append('')
lines.append('## By repo')
lines.append('')
lines.append('| Repo | ok | fail | skip | timeout | transport_fail |')
lines.append('| --- | ---: | ---: | ---: | ---: | ---: |')
for repo in sorted(repo_counts):
    counts = repo_counts[repo]
    lines.append(
        f'| {repo} | {counts.get("ok", 0)} | {counts.get("fail", 0)} | {counts.get("skip", 0)} | {counts.get("timeout", 0)} | {counts.get("transport_fail", 0)} |'
    )

lines.append('')
lines.append('## Failures')
lines.append('')
failure_rows = [row for row in rows if row['status'] in {'fail', 'timeout', 'transport_fail'}]
if not failure_rows:
    lines.append('- none')
else:
    for row in failure_rows:
        lines.append(
            f'- `{row["repo"]}` `{row["workspace"]}` `{row["command"]}`: {row["note"]}'
        )

summary_path.write_text('\n'.join(lines) + '\n', encoding='ascii')
print('\n'.join(lines))
PY
}

enumerate_repositories() {
  local target_path="$1"

  if [[ -d "${target_path}/.git" ]] || git -C "${target_path}" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf '%s\n' "${target_path}"
    return 0
  fi

  for repo_path in "${target_path}"/*; do
    [[ -d "${repo_path}" ]] || continue
    if git -C "${repo_path}" rev-parse --show-toplevel >/dev/null 2>&1; then
      printf '%s\n' "${repo_path}"
    fi
  done
}

log "target root: ${TARGET_ROOT}"
log "tmp root: ${TMP_ROOT}"
log "makevn: ${MAKEVN_BIN}"
log "makevn-mcp: ${MCP_BIN}"

tool_output="$(mcp_list_tools)"
printf '%s\n' "${tool_output}" > "${TOOLS_JSON}"
if [[ "${tool_output}" == *'"name": "doctor"'* && "${tool_output}" == *'"name": "verify_changes"'* && "${tool_output}" == *'"name": "jdk_list"'* ]]; then
  record sweep mcp tools_list ok "MCP tools listed successfully"
else
  record sweep mcp tools_list fail "unexpected MCP tools list"
fi

repo_index=0
while IFS= read -r repo_path; do
  [[ -n "${repo_path}" ]] || continue

  repo_name="$(basename "${repo_path}")"
  clone_path="${TMP_ROOT}/repos/${repo_name}"
  fake_bin="${clone_path}/.repo-sweep/fake-bin"
  docker_log="${REPORT_DIR}/${repo_name}.docker.log"
  workflow="$(workflow_group "${repo_index}")"

  log "repo ${repo_name}: inspecting real repo"
  real_doctor="$(mcp_call "${repo_path}" doctor '{}')"
  if doctor_has "${real_doctor}" 'Repository support status: supported'; then
    record "${repo_name}" real doctor ok "supported"
  else
    record "${repo_name}" real doctor fail "$(summarize_output "${real_doctor}")"
  fi

  log "repo ${repo_name}: cloning into ${clone_path}"
  mkdir -p "${TMP_ROOT}/repos"
  if ! clone_repo "${repo_path}" "${clone_path}"; then
    record "${repo_name}" clone clone fail "git clone failed"
    repo_index=$((repo_index + 1))
    continue
  fi

  setup_fake_docker "${fake_bin}" "${docker_log}"
  export MAKEVN_FAKE_DOCKER_LOG="${docker_log}"

  clone_doctor="$(PATH="${fake_bin}:${PATH}" mcp_call "${clone_path}" doctor '{}')"
  if doctor_has "${clone_doctor}" 'Current makevn status: not initialized'; then
    run_tool "${repo_name}" clone "${clone_path}" init '{}' "${fake_bin}" || true
    clone_doctor="$(PATH="${fake_bin}:${PATH}" mcp_call "${clone_path}" doctor '{}')"
  else
    record "${repo_name}" clone init skip "already initialized"
  fi

  if doctor_has "${clone_doctor}" 'Current makevn status: initialized'; then
    record "${repo_name}" clone doctor ok "initialized clone"
  else
    record "${repo_name}" clone doctor fail "$(summarize_output "${clone_doctor}")"
  fi

  run_tool "${repo_name}" clone "${clone_path}" profile_refresh '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" jdk_current '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" jdk_list '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" exec '{"command": "mvn -v", "context": "code"}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" make_install '{}' "${fake_bin}" || true
  run_make_check "${repo_name}" "${clone_path}" make_vn_doctor || true
  run_tool "${repo_name}" clone "${clone_path}" make_uninstall '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" format '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" checkstyle '{"verbose": true}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" mutation '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" docker_ps '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" docker_stats '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" docker_ps_required '{"wait-seconds": 1}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" docker_ps_required '{"compose": "karate", "wait-seconds": 1}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" docker_up '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" docker_down '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" karate_docker_up '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" karate_docker_down '{}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" karate_test '{"tag": "@smoke"}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" karate_all '{"tag": "@smoke"}' "${fake_bin}" || true
  run_tool "${repo_name}" clone "${clone_path}" stop_app '{}' "${fake_bin}" || true

  log "repo ${repo_name}: running ${workflow}"
  run_workflow_group "${repo_name}" "${clone_path}" "${fake_bin}" "${workflow}"

  run_tool "${repo_name}" clone "${clone_path}" uninstall '{}' "${fake_bin}" || true
  repo_index=$((repo_index + 1))
done < <(enumerate_repositories "${TARGET_ROOT}")

write_summary
log "artifacts: ${REPORT_DIR}"
