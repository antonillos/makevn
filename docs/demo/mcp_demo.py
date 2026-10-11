"""Real stdio MCP demo client; never fabricates tool output."""
import argparse
import json
import subprocess
import os
import select
import tempfile
import time
import sys


def display(value):
    """Keep arrays compact so complete real envelopes fit the recording."""
    def render(item, level=0):
        if isinstance(item, list) and any(isinstance(child, dict) for child in item):
            rows = ["  " * (level + 1) + json.dumps(child, ensure_ascii=False) for child in item]
            return "[\n" + ",\n".join(rows) + "\n" + "  " * level + "]"
        if not isinstance(item, dict):
            return json.dumps(item, ensure_ascii=False)
        rows = ["  " * (level + 1) + json.dumps(key) + ": " + render(child, level + 1)
                for key, child in item.items()]
        return "{\n" + ",\n".join(rows) + "\n" + "  " * level + "}"
    print(render(value), flush=True)


def call(tool, arguments, timeout=300, server="makevn-mcp"):
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "makevn-demo", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": tool, "arguments": arguments}},
    ]
    deadline = time.monotonic() + timeout
    with tempfile.TemporaryFile() as errors, subprocess.Popen(
            [server], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors) as proc:
        buffer = b""

        def receive(identifier):
            nonlocal buffer
            while True:
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line.strip():
                        continue
                    response = json.loads(line)
                    if response.get("id") == identifier:
                        if "error" in response:
                            raise RuntimeError(json.dumps(response["error"]))
                        if "result" not in response:
                            raise RuntimeError("missing MCP result")
                        return response
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([proc.stdout], [], [], remaining)[0]:
                    raise subprocess.TimeoutExpired(server, timeout)
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    errors.seek(0)
                    raise RuntimeError("missing MCP response: " + errors.read().decode(errors="replace"))
                buffer += chunk

        def send(request):
            proc.stdin.write((json.dumps(request) + "\n").encode())
            proc.stdin.flush()

        try:
            send(requests[0])
            receive(1)
            send(requests[1])
            send(requests[2])
            response = receive(2)
            proc.stdin.close()
            proc.wait(timeout=max(0.001, deadline - time.monotonic()))
            if proc.returncode:
                raise RuntimeError("MCP server exited unexpectedly")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    result = response["result"]
    if not isinstance(result, dict):
        raise RuntimeError("invalid MCP result")
    envelope = result.get("structuredContent")
    if envelope is None:
        envelope = json.loads(result["content"][0]["text"])
    if not isinstance(envelope, dict):
        raise RuntimeError("invalid MCP envelope")
    display(envelope)
    if result.get("isError") or envelope["status"] != "success" or envelope["exitCode"] != 0:
        raise RuntimeError("MCP tool execution failed")
    return envelope


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    parser.add_argument("tool", choices=["doctor", "init", "composite_run"])
    args = parser.parse_args()
    arguments = {"repo": args.repo}
    if args.tool == "composite_run":
        arguments.update({"steps": [{"tool": "clean"}, {"tool": "compile"},
                                    {"tool": "package"}], "fail-fast": True})
    display({"name": args.tool, "arguments": arguments})
    try:
        call(args.tool, arguments)
    except (RuntimeError, subprocess.TimeoutExpired, ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
