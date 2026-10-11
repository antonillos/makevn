"""Run a configured agent and reject recordings without completed makevn MCP calls."""
import json
import os
import subprocess
import sys

PROMPT = ("Use only makevn MCP tools: doctor, init if recommended, then composite_run "
          "with clean, compile, package. Do not use shell Maven or trace.")


def failed_result(value):
    if isinstance(value, str):
        try:
            return failed_result(json.loads(value))
        except ValueError:
            return False
    if isinstance(value, dict):
        if value.get("isError") is True or value.get("is_error") is True:
            return True
        if value.get("status") in ("error", "failed") or value.get("failed") is True:
            return True
        if isinstance(value.get("exitCode"), int) and value["exitCode"] != 0:
            return True
        return any(failed_result(child) for child in value.values())
    if isinstance(value, list):
        return any(failed_result(child) for child in value)
    return False


def completed_tools(event):
    found = set()
    if isinstance(event, dict):
        # Codex item.completed MCP event.
        if event.get("type") == "mcp_tool_call" and event.get("server") == "makevn" and event.get("status") == "completed" and not event.get("error") and not failed_result(event.get("result")):
            found.add(event.get("tool"))
        # OpenCode completed tool part.
        tool = event.get("tool", "")
        state = event.get("state", {})
        if isinstance(tool, str) and tool.startswith("makevn_") and isinstance(state, dict) and state.get("status") == "completed" and not failed_result(state.get("output")):
            found.add(tool.removeprefix("makevn_"))
        for value in event.values():
            found.update(completed_tools(value))
    elif isinstance(event, list):
        for value in event:
            found.update(completed_tools(value))
    return found


def main():
    client = sys.argv[1]
    commands = {"codex": ["codex", "exec", "--ephemeral", "-c",
                          "mcp_servers.makevn.command=" + json.dumps(os.environ["MAKEVN_DEMO_PREFIX"] + "/bin/makevn-mcp"),
                          "--json", PROMPT],
                "opencode": ["opencode", "run", "--format", "json", PROMPT]}
    seen = set()
    try:
        proc = subprocess.run(commands[client], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        print("Agent timed out; recording rejected.", file=sys.stderr)
        return 1
    if proc.stderr:
        print(proc.stderr, file=sys.stderr)
    for line in proc.stdout.splitlines():
        print(line, flush=True)
        try:
            seen.update(completed_tools(json.loads(line)))
        except ValueError:
            pass
    code = proc.returncode
    if code:
        return code
    if not {"doctor", "composite_run"} <= seen:
        print("Recording rejected: completed makevn MCP doctor/composite_run calls not found.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
