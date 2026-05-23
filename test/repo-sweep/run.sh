#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_TARGET_ROOT="${PWD}"
DEFAULT_TMP_BASE="${TMPDIR:-/tmp}"
SWEEP_PROFILE="${MAKEVN_REPO_SWEEP_PROFILE:-quick}"
TARGET_ROOT="${MAKEVN_REPO_SWEEP_ROOT:-${DEFAULT_TARGET_ROOT}}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { printf 'Missing value for --profile\n' >&2; exit 2; }
      SWEEP_PROFILE="$2"
      shift 2
      ;;
    --help|-h)
      cat <<'EOF'
Usage: test/repo-sweep/run.sh [--profile quick|full|destructive] [REPO_OR_ROOT]

Profiles:
  quick        MCP contract, init/adoption, JDK, make integration, classifiers
  full         quick + build/test/coverage command groups and read-only probes
  destructive  full + docker/karate lifecycle probes against the cloned repo

Environment:
  MAKEVN_REPO_SWEEP_TIMEOUT_SECONDS  Per-command timeout, default 45
  MAKEVN_REPO_SWEEP_CACHE_DIR        Persistent doctor cache directory
  MAKEVN_REPO_SWEEP_INSTALL_PREFIX   Reusable makevn install prefix
  MAKEVN_REPO_SWEEP_MUTATION=1       Enable PIT mutation command
  MAKEVN_REPO_SWEEP_FAIL_ON_PRODUCT_BUG=0  Always exit 0 after report
EOF
      exit 0
      ;;
    *)
      TARGET_ROOT="$1"
      shift
      ;;
  esac
done
case "${SWEEP_PROFILE}" in
  quick|full|destructive) ;;
  *) printf 'Unknown profile: %s\n' "${SWEEP_PROFILE}" >&2; exit 2 ;;
esac
TMP_BASE="${MAKEVN_REPO_SWEEP_TMP_BASE:-${DEFAULT_TMP_BASE}}"
TMP_ROOT="$(mktemp -d "${TMP_BASE%/}/makevn-repo-sweep.XXXXXX")"
REPORT_DIR="${TMP_ROOT}/report"
RESULTS_TSV="${REPORT_DIR}/results.tsv"
SUMMARY_MD="${REPORT_DIR}/summary.md"
TOOLS_JSON="${REPORT_DIR}/tools.json"
COMMAND_TIMEOUT_SECONDS="${MAKEVN_REPO_SWEEP_TIMEOUT_SECONDS:-45}"
CACHE_DIR="${MAKEVN_REPO_SWEEP_CACHE_DIR:-${TMP_BASE%/}/makevn-repo-sweep-cache}"
MUTATION_ENABLED="${MAKEVN_REPO_SWEEP_MUTATION:-0}"
EXIT_ON_PRODUCT_BUG="${MAKEVN_REPO_SWEEP_FAIL_ON_PRODUCT_BUG:-1}"

MAKEVN_BIN="${MAKEVN_BIN:-${ROOT_DIR}/target/release/makevn}"
MCP_BIN="${MCP_BIN:-${ROOT_DIR}/target/release/makevn-mcp}"
INSTALL_PREFIX="${MAKEVN_REPO_SWEEP_INSTALL_PREFIX:-${TMP_ROOT}/install-prefix}"
INSTALL_BIN_DIR="${INSTALL_PREFIX}/bin"

mkdir -p "${REPORT_DIR}" "${CACHE_DIR}"
printf 'repo\tworkspace\tcommand\tstatus\tclassification\tnote\n' > "${RESULTS_TSV}"

resolve_bin() {
  local candidate="$1"
  local fallback="$2"

  if [[ -x "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  command -v "${fallback}"
}

if [[ -n "${MAKEVN_REPO_SWEEP_INSTALL_PREFIX:-}" && -x "${INSTALL_BIN_DIR}/makevn" && -x "${INSTALL_BIN_DIR}/makevn-mcp" ]]; then
  MAKEVN_BIN="${INSTALL_BIN_DIR}/makevn"
  MCP_BIN="${INSTALL_BIN_DIR}/makevn-mcp"
elif [[ -x "${ROOT_DIR}/target/release/makevn" && -x "${ROOT_DIR}/target/release/makevn-mcp" ]]; then
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
  local classification="$5"
  local note="$6"

  note="${note//$'\n'/ | }"
  note="${note//$'\t'/ }"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${repo_name}" \
    "${workspace}" \
    "${command_name}" \
    "${status}" \
    "${classification}" \
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

classify_result() {
  local command_name="$1"
  local status="$2"
  local output="$3"
  local doctor_output="$4"

  if [[ "${status}" == "ok" ]]; then
    printf 'ok\n'
    return 0
  fi
  if [[ "${status}" == "timeout" ]]; then
    printf 'slow_path\n'
    return 0
  fi
  if [[ "${status}" == "transport_fail" ]]; then
    printf 'tooling_error\n'
    return 0
  fi

  case "${output}" in
    *"Could not resolve code JDK"*|*"Resolved code JAVA_HOME: unresolved"*)
      printf 'environment_missing\n'
      return 0
      ;;
    *"No formatting plugin configured"*|*"No Checkstyle plugin configured"*|*"No PIT mutation plugin detected"*)
      printf 'expected_unavailable\n'
      return 0
      ;;
    *"Docker compose file not found"*|*"Karate docker compose file not found"*|*"No Karate Maven project detected"*)
      printf 'expected_unavailable\n'
      return 0
      ;;
    *"JaCoCo report"*"not found"*|*"no classes or execution data"*)
      printf 'expected_unavailable\n'
      return 0
      ;;
    *"Unknown command:"*|*"Usage: makevn"*|*"Unrecognized option: --context"*)
      printf 'product_bug\n'
      return 0
      ;;
  esac

  case "${command_name}" in
    format|checkstyle|coverage|coverage_changes|karate_test|karate_all|karate_docker_up|karate_docker_down)
      printf 'expected_unavailable\n'
      ;;
    mutation)
      printf 'slow_path\n'
      ;;
    docker_up|docker_down|docker_ps_required)
      if [[ "${doctor_output}" == *"Docker compose file: not found"* || "${doctor_output}" == *"Docker compose file: ambiguous"* ]]; then
        printf 'expected_unavailable\n'
      else
        printf 'repo_failure\n'
      fi
      ;;
    *)
      printf 'repo_failure\n'
      ;;
  esac
}

record_skip() {
  local repo_name="$1"
  local workspace="$2"
  local command_name="$3"
  local classification="$4"
  local note="$5"

  record "${repo_name}" "${workspace}" "${command_name}" skip "${classification}" "${note}"
}

doctor_cache_key() {
  local repo_path="$1"

  python3 - "${repo_path}" <<'PY'
import hashlib
import pathlib
import subprocess
import sys

repo = pathlib.Path(sys.argv[1]).resolve()
try:
    head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
except Exception:
    head = 'nogit'
sha = hashlib.sha256()
sha.update(str(repo).encode())
sha.update(b'\0')
sha.update(head.encode())
for relative in ['pom.xml', '.tool-versions']:
    path = repo / relative
    if path.is_file():
        sha.update(relative.encode())
        sha.update(path.read_bytes())
workflow_dir = repo / '.github' / 'workflows'
if workflow_dir.is_dir():
    for path in sorted(workflow_dir.glob('*.yml')) + sorted(workflow_dir.glob('*.yaml')):
        sha.update(str(path.relative_to(repo)).encode())
        sha.update(path.read_bytes())
print(sha.hexdigest())
PY
}

cached_doctor() {
  local repo_path="$1"
  local fake_path_prefix="${2:-}"
  local key=""
  local cache_file=""
  local tmp_file=""

  key="$(doctor_cache_key "${repo_path}")"
  cache_file="${CACHE_DIR}/${key}.doctor.txt"
  if [[ -s "${cache_file}" ]]; then
    printf '%s\n' "$(<"${cache_file}")"
    return 0
  fi
  if [[ -n "${fake_path_prefix}" ]]; then
    PATH="${fake_path_prefix}:${PATH}" mcp_call "${repo_path}" doctor '{}'
  else
    tmp_file="${cache_file}.$$"
    mcp_call "${repo_path}" doctor '{}' | tee "${tmp_file}"
    if [[ -s "${tmp_file}" ]]; then
      mv "${tmp_file}" "${cache_file}"
    else
      rm -f "${tmp_file}"
    fi
  fi
}

doctor_indicates() {
  local doctor_output="$1"
  local command_name="$2"

  case "${command_name}" in
    format)
      [[ "${doctor_output}" == *"MAKEVN_FORMAT_CHECK_GOAL"* || "${doctor_output}" == *"spotless"* || "${doctor_output}" == *"formatter"* ]]
      ;;
    checkstyle)
      [[ "${doctor_output}" == *"checkstyle"* || "${doctor_output}" == *"MAKEVN_CHECKSTYLE_GOAL"* ]]
      ;;
    docker_ps_required|docker_up|docker_down)
      [[ "${doctor_output}" != *"Docker compose file: not found"* && "${doctor_output}" != *"Docker compose file: ambiguous"* ]]
      ;;
    karate_docker_up|karate_docker_down|karate_test|karate_all)
      [[ "${doctor_output}" != *"Docker e2e compose file: not found"* || "${doctor_output}" == *"Karate .tool-versions:"*"/"* ]]
      ;;
    coverage|coverage_changes|verify_ut_coverage|verify_it_coverage)
      [[ "${doctor_output}" != *"JaCoCo report layout: not detected"* || "${doctor_output}" != *"Detected coverage activation: none"* ]]
      ;;
    mutation)
      [[ "${doctor_output}" == *"Mutation testing (PIT): yes"* ]]
      ;;
    *)
      return 0
      ;;
  esac
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
  local doctor_output="${7:-}"
  local output=""
  local cmd_status=0
  local exit_code=0
  local status="ok"
  local note=""
  local classification="ok"

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
    classification="$(classify_result "${command_name}" "${status}" "${output}" "${doctor_output}")"
    record "${repo_name}" "${workspace}" "${command_name}" "${status}" "${classification}" "${note}"
    return 1
  fi

  exit_code="$(extract_exit_code "${output}")"
  note="$(summarize_output "${output}")"
  if [[ "${exit_code}" != "0" ]]; then
    status="fail"
  fi
  classification="$(classify_result "${command_name}" "${status}" "${output}" "${doctor_output}")"

  record "${repo_name}" "${workspace}" "${command_name}" "${status}" "${classification}" "${note}"

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
    record_skip "${repo_name}" clone "${command_name}" expected_unavailable "missing .makevn/makevn.mk"
    return 0
  fi

  if PATH="${INSTALL_BIN_DIR}:${PATH}" make -f "${repo_path}/.makevn/makevn.mk" -C "${repo_path}" MAKEVN_BIN="${MAKEVN_BIN}" vn-doctor >/dev/null 2>&1; then
    record "${repo_name}" clone "${command_name}" ok ok "vn-doctor succeeded"
    return 0
  fi

  record "${repo_name}" clone "${command_name}" fail product_bug "vn-doctor failed"
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
  local doctor_output="$5"

  if [[ "${SWEEP_PROFILE}" == "quick" ]]; then
    record_skip "${repo_name}" clone "${group_name}" slow_path "profile quick skips Maven lifecycle group"
    return 0
  fi

  case "${group_name}" in
    build_cycle)
      run_tool "${repo_name}" clone "${repo_path}" validate '{}' "${path_prefix}" "${doctor_output}" || true
      run_tool "${repo_name}" clone "${repo_path}" compile '{}' "${path_prefix}" "${doctor_output}" || true
      run_tool "${repo_name}" clone "${repo_path}" package '{}' "${path_prefix}" "${doctor_output}" || true
      run_tool "${repo_name}" clone "${repo_path}" clean '{}' "${path_prefix}" "${doctor_output}" || true
      run_tool "${repo_name}" clone "${repo_path}" build '{}' "${path_prefix}" "${doctor_output}" || true
      ;;
    test_cycle)
      run_tool "${repo_name}" clone "${repo_path}" test_compile '{}' "${path_prefix}" "${doctor_output}" || true
      run_tool "${repo_name}" clone "${repo_path}" compile_tests '{}' "${path_prefix}" "${doctor_output}" || true
      run_tool "${repo_name}" clone "${repo_path}" test '{"fast": true}' "${path_prefix}" "${doctor_output}" || true
      run_tool "${repo_name}" clone "${repo_path}" verify_ut '{}' "${path_prefix}" "${doctor_output}" || true
      ;;
    verify_cycle)
      run_tool "${repo_name}" clone "${repo_path}" verify_it '{}' "${path_prefix}" "${doctor_output}" || true
      run_tool "${repo_name}" clone "${repo_path}" verify '{}' "${path_prefix}" "${doctor_output}" || true
      run_tool "${repo_name}" clone "${repo_path}" verify_changes '{}' "${path_prefix}" "${doctor_output}" || true
      run_tool "${repo_name}" clone "${repo_path}" pr_verify '{}' "${path_prefix}" "${doctor_output}" || true
      ;;
    coverage_cycle)
      run_tool "${repo_name}" clone "${repo_path}" clean '{}' "${path_prefix}" "${doctor_output}" || true
      if doctor_indicates "${doctor_output}" verify_ut_coverage; then
        run_tool "${repo_name}" clone "${repo_path}" verify_ut_coverage '{}' "${path_prefix}" "${doctor_output}" || true
        run_tool "${repo_name}" clone "${repo_path}" coverage '{}' "${path_prefix}" "${doctor_output}" || true
        run_tool "${repo_name}" clone "${repo_path}" coverage_changes '{}' "${path_prefix}" "${doctor_output}" || true
      else
        record_skip "${repo_name}" clone verify_ut_coverage expected_unavailable "doctor did not detect coverage strategy"
        record_skip "${repo_name}" clone coverage expected_unavailable "doctor did not detect JaCoCo report"
        record_skip "${repo_name}" clone coverage_changes expected_unavailable "doctor did not detect coverage strategy"
      fi
      run_tool "${repo_name}" clone "${repo_path}" verify_it_coverage '{}' "${path_prefix}" "${doctor_output}" || true
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
classification_counts = Counter(row['classification'] for row in rows)
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
if classification_counts.get('product_bug', 0) or classification_counts.get('tooling_error', 0):
    verdict = 'action-required'
elif classification_counts.get('repo_failure', 0) or classification_counts.get('environment_missing', 0):
    verdict = 'repo-or-environment-issues'
else:
    verdict = 'clean'
lines.append(f'- verdict: {verdict}')
lines.append('')
lines.append('## By classification')
lines.append('')
for classification, count in sorted(classification_counts.items()):
    lines.append(f'- {classification}: {count}')
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
lines.append('## Agent Action')
lines.append('')
if verdict == 'action-required':
    lines.append('- Fix makevn or the sweep harness before trusting this run.')
    lines.append('- Prioritize rows classified as `product_bug` or `tooling_error`.')
elif verdict == 'repo-or-environment-issues':
    lines.append('- makevn reached the target commands; remaining issues belong to repository capability or local environment.')
    lines.append('- Do not edit fixture repositories unless the human explicitly asks.')
else:
    lines.append('- No makevn product issues detected in this sweep profile.')
lines.append('')
lines.append('## Failures')
lines.append('')
failure_rows = [row for row in rows if row['status'] in {'fail', 'timeout', 'transport_fail'}]
if not failure_rows:
    lines.append('- none')
else:
    for row in failure_rows:
        lines.append(
        f'- `{row["repo"]}` `{row["workspace"]}` `{row["command"]}` `{row["classification"]}`: {row["note"]}'
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
log "profile: ${SWEEP_PROFILE}"
log "cache: ${CACHE_DIR}"
log "makevn: ${MAKEVN_BIN}"
log "makevn-mcp: ${MCP_BIN}"
log "report summary: ${SUMMARY_MD}"
log "report results: ${RESULTS_TSV}"
log "report tools: ${TOOLS_JSON}"

tool_output="$(mcp_list_tools)"
printf '%s\n' "${tool_output}" > "${TOOLS_JSON}"
if [[ "${tool_output}" == *'"name": "doctor"'* && "${tool_output}" == *'"name": "verify_changes"'* && "${tool_output}" == *'"name": "jdk_list"'* ]]; then
  record sweep mcp tools_list ok ok "MCP tools listed successfully"
else
  record sweep mcp tools_list fail product_bug "unexpected MCP tools list"
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
  real_doctor="$(cached_doctor "${repo_path}")"
  if doctor_has "${real_doctor}" 'Repository support status: supported'; then
    record "${repo_name}" real doctor ok ok "supported"
  else
    record "${repo_name}" real doctor fail expected_unavailable "$(summarize_output "${real_doctor}")"
  fi

  log "repo ${repo_name}: cloning into ${clone_path}"
  mkdir -p "${TMP_ROOT}/repos"
  if ! clone_repo "${repo_path}" "${clone_path}"; then
    record "${repo_name}" clone clone fail tooling_error "git clone failed"
    repo_index=$((repo_index + 1))
    continue
  fi

  setup_fake_docker "${fake_bin}" "${docker_log}"
  export MAKEVN_FAKE_DOCKER_LOG="${docker_log}"

  clone_doctor="$(cached_doctor "${clone_path}" "${fake_bin}")"
  if doctor_has "${clone_doctor}" 'Current makevn status: not initialized'; then
    run_tool "${repo_name}" clone "${clone_path}" init '{}' "${fake_bin}" "${clone_doctor}" || true
    clone_doctor="$(PATH="${fake_bin}:${PATH}" mcp_call "${clone_path}" doctor '{}')"
  else
    record_skip "${repo_name}" clone init ok "already initialized"
  fi

  if doctor_has "${clone_doctor}" 'Current makevn status: initialized'; then
    record "${repo_name}" clone doctor ok ok "initialized clone"
  else
    record "${repo_name}" clone doctor fail product_bug "$(summarize_output "${clone_doctor}")"
  fi

  run_tool "${repo_name}" clone "${clone_path}" profile_refresh '{}' "${fake_bin}" "${clone_doctor}" || true
  run_tool "${repo_name}" clone "${clone_path}" jdk_current '{}' "${fake_bin}" "${clone_doctor}" || true
  run_tool "${repo_name}" clone "${clone_path}" jdk_list '{}' "${fake_bin}" "${clone_doctor}" || true
  run_tool "${repo_name}" clone "${clone_path}" exec '{"command": "mvn -v", "context": "code"}' "${fake_bin}" "${clone_doctor}" || true
  run_tool "${repo_name}" clone "${clone_path}" make_install '{}' "${fake_bin}" "${clone_doctor}" || true
  run_make_check "${repo_name}" "${clone_path}" make_vn_doctor || true
  run_tool "${repo_name}" clone "${clone_path}" make_uninstall '{}' "${fake_bin}" "${clone_doctor}" || true

  if doctor_indicates "${clone_doctor}" format; then
    run_tool "${repo_name}" clone "${clone_path}" format '{}' "${fake_bin}" "${clone_doctor}" || true
  else
    record_skip "${repo_name}" clone format expected_unavailable "doctor did not detect formatter"
  fi
  if doctor_indicates "${clone_doctor}" checkstyle; then
    run_tool "${repo_name}" clone "${clone_path}" checkstyle '{"verbose": true}' "${fake_bin}" "${clone_doctor}" || true
  else
    record_skip "${repo_name}" clone checkstyle expected_unavailable "doctor did not detect Checkstyle"
  fi
  if [[ "${MUTATION_ENABLED}" == "1" ]] && doctor_indicates "${clone_doctor}" mutation; then
    run_tool "${repo_name}" clone "${clone_path}" mutation '{}' "${fake_bin}" "${clone_doctor}" || true
  else
    record_skip "${repo_name}" clone mutation slow_path "mutation requires MAKEVN_REPO_SWEEP_MUTATION=1 and PIT support"
  fi

  run_tool "${repo_name}" clone "${clone_path}" docker_ps '{}' "${fake_bin}" "${clone_doctor}" || true
  run_tool "${repo_name}" clone "${clone_path}" docker_stats '{}' "${fake_bin}" "${clone_doctor}" || true
  if doctor_indicates "${clone_doctor}" docker_ps_required; then
    run_tool "${repo_name}" clone "${clone_path}" docker_ps_required '{"wait-seconds": 1}' "${fake_bin}" "${clone_doctor}" || true
  else
    record_skip "${repo_name}" clone docker_ps_required expected_unavailable "doctor did not detect boot compose"
  fi
  if doctor_indicates "${clone_doctor}" karate_test; then
    run_tool "${repo_name}" clone "${clone_path}" docker_ps_required '{"compose": "karate", "wait-seconds": 1}' "${fake_bin}" "${clone_doctor}" || true
    run_tool "${repo_name}" clone "${clone_path}" karate_test '{"tag": "@smoke"}' "${fake_bin}" "${clone_doctor}" || true
  else
    record_skip "${repo_name}" clone docker_ps_required_karate expected_unavailable "doctor did not detect Karate compose"
    record_skip "${repo_name}" clone karate_test expected_unavailable "doctor did not detect Karate project"
  fi
  if [[ "${SWEEP_PROFILE}" == "destructive" ]]; then
    if doctor_indicates "${clone_doctor}" docker_up; then
      run_tool "${repo_name}" clone "${clone_path}" docker_up '{}' "${fake_bin}" "${clone_doctor}" || true
      run_tool "${repo_name}" clone "${clone_path}" docker_down '{}' "${fake_bin}" "${clone_doctor}" || true
    else
      record_skip "${repo_name}" clone docker_up expected_unavailable "doctor did not detect boot compose"
      record_skip "${repo_name}" clone docker_down expected_unavailable "doctor did not detect boot compose"
    fi
    if doctor_indicates "${clone_doctor}" karate_docker_up; then
      run_tool "${repo_name}" clone "${clone_path}" karate_docker_up '{}' "${fake_bin}" "${clone_doctor}" || true
      run_tool "${repo_name}" clone "${clone_path}" karate_docker_down '{}' "${fake_bin}" "${clone_doctor}" || true
      run_tool "${repo_name}" clone "${clone_path}" karate_all '{"tag": "@smoke"}' "${fake_bin}" "${clone_doctor}" || true
    else
      record_skip "${repo_name}" clone karate_docker_up expected_unavailable "doctor did not detect Karate compose"
      record_skip "${repo_name}" clone karate_docker_down expected_unavailable "doctor did not detect Karate compose"
      record_skip "${repo_name}" clone karate_all expected_unavailable "doctor did not detect Karate project"
    fi
  else
    record_skip "${repo_name}" clone docker_up slow_path "profile ${SWEEP_PROFILE} skips lifecycle command"
    record_skip "${repo_name}" clone docker_down slow_path "profile ${SWEEP_PROFILE} skips lifecycle command"
    record_skip "${repo_name}" clone karate_docker_up slow_path "profile ${SWEEP_PROFILE} skips lifecycle command"
    record_skip "${repo_name}" clone karate_docker_down slow_path "profile ${SWEEP_PROFILE} skips lifecycle command"
    record_skip "${repo_name}" clone karate_all slow_path "profile ${SWEEP_PROFILE} skips lifecycle command"
  fi
  run_tool "${repo_name}" clone "${clone_path}" stop_app '{}' "${fake_bin}" "${clone_doctor}" || true

  log "repo ${repo_name}: running ${workflow}"
  run_workflow_group "${repo_name}" "${clone_path}" "${fake_bin}" "${workflow}" "${clone_doctor}"

  run_tool "${repo_name}" clone "${clone_path}" uninstall '{}' "${fake_bin}" "${clone_doctor}" || true
  repo_index=$((repo_index + 1))
done < <(enumerate_repositories "${TARGET_ROOT}")

write_summary
log "artifacts: ${REPORT_DIR}"
log "summary: ${SUMMARY_MD}"
log "results: ${RESULTS_TSV}"
log "tools: ${TOOLS_JSON}"
if [[ "${EXIT_ON_PRODUCT_BUG}" == "1" ]] && python3 - "${RESULTS_TSV}" <<'PY'
import csv
import sys

rows = csv.DictReader(open(sys.argv[1]), delimiter='\t')
raise SystemExit(0 if any(row['classification'] in {'product_bug', 'tooling_error'} for row in rows) else 1)
PY
then
  exit 1
fi
