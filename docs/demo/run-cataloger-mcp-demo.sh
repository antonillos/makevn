#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:?usage: run-cataloger-mcp-demo.sh <repo-root>}"
module_repo="${repo_root}/cataloger-cli"

python3 - "${repo_root}" "${module_repo}" <<'PY'
import json
import subprocess
import sys

repo_root, module_repo = sys.argv[1:3]

calls = [
    ("doctor", {"repo": repo_root}),
    ("clean", {"repo": module_repo}),
    ("compile", {"repo": module_repo}),
    ("package", {"repo": module_repo}),
]


def call(tool, arguments, timeout):
    requests = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "makevn-demo", "version": "0"},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": tool, "arguments": arguments},
        },
    ]
    proc = subprocess.Popen(
        ["makevn-mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    stdout, stderr = proc.communicate(
        "\n".join(json.dumps(request) for request in requests) + "\n",
        timeout=timeout,
    )
    if proc.returncode != 0:
        sys.stderr.write((stderr or stdout).strip() + "\n")
        raise SystemExit(proc.returncode)
    response = None
    for line in stdout.splitlines():
        if not line.strip():
            continue
        message = json.loads(line)
        if message.get("id") == 2:
            response = message
    if response is None:
        sys.stderr.write("missing MCP response\n")
        raise SystemExit(92)
    if "error" in response:
        sys.stderr.write(response["error"].get("message", "unknown MCP error") + "\n")
        raise SystemExit(93)
    for part in response.get("result", {}).get("content", []):
        if part.get("type") == "text" and part.get("text"):
            sys.stdout.write(part["text"].rstrip() + "\n")


for tool, arguments in calls:
    timeout = 300 if tool in {"compile", "package"} else 120
    call(tool, arguments, timeout)
PY
