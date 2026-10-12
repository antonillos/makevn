"""Exercise ownership, conflicts and cancellation through the real stdio server."""
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


def eventually(predicate, timeout=9):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(0.03)
    raise AssertionError("Timed out waiting for execution state")


def alive(pid):
    output = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                            capture_output=True, text=True, check=False).stdout.strip()
    return bool(output) and not output.startswith("Z")


class Session:
    def __init__(self, executable, state):
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, bufsize=1,
                                        env={**os.environ, "XDG_STATE_HOME": str(state)})
        self.replies = queue.Queue()
        self.pending = {}
        self.next_id = 1
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        self.call_method("initialize", {"protocolVersion": "2025-11-25"})
        self.send("notifications/initialized", {})

    def read(self):
        for line in self.process.stdout:
            self.replies.put(json.loads(line))

    def send(self, method, params, request_id=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            message["id"] = request_id
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def begin(self, name, **args):
        request_id = self.next_id
        self.next_id += 1
        self.send("tools/call", {"name": name, "arguments": args}, request_id)
        return request_id

    def receive(self, request_id, timeout=10):
        deadline = time.monotonic() + timeout
        while request_id not in self.pending:
            try:
                response = self.replies.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty:
                raise AssertionError(f"No response for request {request_id}") from None
            self.pending[response["id"]] = response
        return self.pending.pop(request_id)

    def call_method(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self.send(method, params, request_id)
        return self.receive(request_id)

    def call(self, name, **args):
        response = self.receive(self.begin(name, **args))
        result = response["result"]
        assert json.loads(result["content"][0]["text"]) == result["structuredContent"]
        return result

    def executions(self, **args):
        return self.call("execution_list", **args)["structuredContent"]["executions"]

    def status(self, execution_id):
        return self.call("execution_status", executionId=execution_id)["structuredContent"]["execution"]

    def running(self, repo):
        return eventually(lambda: next((record for record in self.executions(repo=str(repo))
                                       if record["state"] == "running"), None))

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=12)
        self.reader.join(timeout=1)
        error = self.process.stderr.read()
        assert self.process.returncode == 0, error


BACKEND = r'''import os
from pathlib import Path
import signal
import subprocess
import sys
import time

args = sys.argv[1:]
repo = Path(args[args.index('--repo') + 1]) if '--repo' in args else Path.cwd()
command = next(arg for arg in args if arg in ['doctor', 'verify-changes-preview', 'verify-changes', 'verify', 'verify-ut', 'verify-it', 'clean', 'mutation', 'run-app-bg'])
if command in ['doctor', 'verify-changes-preview']:
    assert os.environ['MAKEVN_MCP_INSPECTION'] == '1'
    print('inspection completed')
    sys.exit(0)
assert 'MAKEVN_MCP_INSPECTION' not in os.environ
with (repo / 'started').open('a') as file:
    file.write(command + '\n')
if command in ['clean', 'mutation', 'run-app-bg'] or (repo / 'quick').exists():
    print('completed')
    sys.exit(0)
if (repo / 'ignore').exists():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
with (repo / 'pids').open('a') as file:
    file.write(str(os.getpid()) + '\n')
subprocess.Popen([sys.executable, str(Path(__file__).with_name('child.py')), str(repo)])
phase = os.environ.get('MAKEVN_MCP_PHASE_OUT')
if phase:
    Path(phase).write_text('controlled verification phase\n')
print('[..] makevn verify | log: .makevn/logs/verify.log', flush=True)
while True:
    time.sleep(0.1)
'''

CHILD = r'''import os
from pathlib import Path
import signal
import subprocess
import sys
import time

repo = Path(sys.argv[1])
if (repo / 'ignore').exists():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
with (repo / 'pids').open('a') as file:
    file.write(str(os.getpid()) + '\n')
if len(sys.argv) == 2:
    subprocess.Popen([sys.executable, __file__, str(repo), 'grandchild'])
while True:
    time.sleep(0.1)
'''


def pids(repo, count=3):
    def read():
        path = repo / "pids"
        values = [int(pid) for pid in path.read_text().splitlines()] if path.exists() else []
        return values if len(values) >= count else None
    return eventually(read)


def stopped(session, record, owned):
    terminal = eventually(lambda: (status if (status := session.status(record["executionId"]))["state"]
                                  in ["cancelled", "failed", "succeeded"] else None))
    assert terminal["state"] == "cancelled", terminal
    assert terminal["exitCode"] == 130
    eventually(lambda: all(not alive(pid) for pid in owned))
    assert terminal["logPaths"] and all(Path(path).exists() for path in terminal["logPaths"] if Path(path).is_absolute())
    return terminal


def responsiveness_and_cancellation(first, second, repo, other):
    request = first.begin("verify_changes", repo=str(repo))
    record = first.running(repo)
    owned = pids(repo)
    assert record["sessionId"]
    start = time.monotonic()
    assert first.call("doctor", repo=str(repo))["isError"] is False
    assert first.call("verify_changes_preview", repo=str(repo))["isError"] is False
    assert first.status(record["executionId"])["currentPhase"] == "controlled verification phase"
    assert time.monotonic() - start < 3
    conflict = second.call("verify", repo=str(repo))
    assert conflict["isError"] is True
    assert record["executionId"] in conflict["structuredContent"]["untrustedData"]["output"]
    denied = second.call("execution_cancel", executionId=record["executionId"])
    assert denied["isError"] is True
    alias = repo.parent / "alias"
    alias.symlink_to(repo, target_is_directory=True)
    assert second.call("verify", repo=str(alias))["isError"] is True
    other_request = second.begin("verify", repo=str(other))
    other_record = second.running(other)
    other_owned = pids(other)
    cancelled = first.call("execution_cancel", executionId=record["executionId"])
    assert cancelled["structuredContent"]["executionState"] in ["cancelling", "cancelled"]
    terminal = stopped(first, record, owned)
    repeated = first.call("execution_cancel", executionId=record["executionId"])
    assert repeated["structuredContent"]["execution"]["state"] == "cancelled"
    assert all(alive(pid) for pid in other_owned)
    response = first.receive(request)["result"]
    assert response["isError"] is True
    assert response["structuredContent"]["executionState"] == "cancelled"
    assert response["structuredContent"]["durationMs"] >= 0
    assert "cancelled" in response["structuredContent"]["nextSuggestion"].lower()
    second.call("execution_cancel", executionId=other_record["executionId"])
    stopped(second, other_record, other_owned)
    second.receive(other_request)
    assert terminal["executionId"] in [item["executionId"] for item in first.executions(includeFinished=True)]


def pr_conflicts(first, second, left, right):
    request = first.begin("verify", repo=str(left), pr="https://GitHub.com/Owner/Repo/pull/42/")
    record = first.running(left)
    owned = pids(left)
    conflict = second.call("verify", repo=str(right), pr="http://github.com/owner/repo/pull/042")
    assert conflict["isError"] is True
    assert record["executionId"] in conflict["structuredContent"]["untrustedData"]["output"]
    right_request = second.begin("verify", repo=str(right), pr="https://github.com/owner/repo/pull/43")
    right_record = second.running(right)
    right_owned = pids(right)
    first.call("execution_cancel", executionId=record["executionId"])
    stopped(first, record, owned)
    first.receive(request)
    assert all(alive(pid) for pid in right_owned)
    second.call("execution_cancel", executionId=right_record["executionId"])
    stopped(second, right_record, right_owned)
    second.receive(right_request)
    for invalid in ["file:///secret", "https://github.com/owner/repo/issues/42"]:
        assert first.call("verify", repo=str(left), pr=invalid)["isError"] is True


def notification_and_workflows(session, repo, parallel):
    request_id = "string-verification-id"
    session.send("tools/call", {"name": "composite_run", "arguments": {
        "repo": str(repo), "fail-fast": False, "steps": [{"tool": "verify"}, {"tool": "clean"}]
    }}, request_id)
    record = session.running(repo)
    owned = pids(repo)
    session.send("notifications/cancelled", {"requestId": request_id})
    stopped(session, record, owned)
    assert (repo / "started").read_text().splitlines() == ["verify"]
    session.send("notifications/cancelled", {"requestId": "unknown"})
    session.send("notifications/cancelled", {})
    session.call("execution_list")
    assert request_id not in session.pending
    assert first_unknown(session)["error"]["code"] == -32602
    invalid = session.call("composite_run", repo=str(repo), steps=[{"tool": "clean"}, {"tool": "invalid"}])
    assert invalid["isError"] is True
    assert (repo / "started").read_text().splitlines() == ["verify"]
    parallel_request = session.begin("parallel_run", repo=str(parallel), steps=[{"tool": "verify_ut"}, {"tool": "verify_it"}])
    record = session.running(parallel)
    owned = pids(parallel, 6)
    session.call("execution_cancel", executionId=record["executionId"])
    stopped(session, record, owned)
    response = session.receive(parallel_request)["result"]["structuredContent"]
    assert response["executionState"] == "cancelled"
    assert response["untrustedData"]["workflow"]["executedSteps"] == 2


def first_unknown(session):
    return session.receive(session.begin("does_not_exist"))


def completion_and_forcing(session, quick, forced):
    (quick / "quick").touch()
    result = session.call("verify", repo=str(quick))["structuredContent"]
    assert result["executionState"] == "succeeded"
    cancelled = session.call("execution_cancel", executionId=result["executionId"])
    assert cancelled["structuredContent"]["executionState"] == "succeeded"
    session.send("notifications/cancelled", {"requestId": -1})
    (forced / "ignore").touch()
    request = session.begin("verify", repo=str(forced))
    record = session.running(forced)
    owned = pids(forced)
    start = time.monotonic()
    session.call("execution_cancel", executionId=record["executionId"])
    conflict = session.call("verify", repo=str(forced))
    assert conflict["isError"] is True
    assert record["executionId"] in conflict["structuredContent"]["untrustedData"]["output"]
    stopped(session, record, owned)
    elapsed = time.monotonic() - start
    assert 4.5 <= elapsed < 8, elapsed
    session.receive(request)
    assert session.call("execution_status", executionId="../private")["isError"] is True
    assert session.call("execution_status")["isError"] is True
    assert session.call("execution_list", includeFinished="yes")["isError"] is True
    assert session.call("execution_list", unknown=True)["isError"] is True


def disconnect(executable, state, observer, repo, mode):
    client = Session(executable, state)
    client.begin("verify", repo=str(repo))
    record = client.running(repo)
    owned = pids(repo)
    if mode == "kill":
        client.process.kill()
        client.process.wait(timeout=2)
    elif mode == "signal":
        client.process.terminate()
        client.process.wait(timeout=10)
        client.close()
    elif mode == "invalid":
        client.process.stdin.write("invalid JSON\n" + json.dumps({"jsonrpc":"2.0","id":99,"method":"tools/list"}) + "\n")
        client.process.stdin.flush()
        client.process.wait(timeout=10)
        assert client.process.returncode == 1
    else:
        client.close()
    stopped(observer, record, owned)
    (repo / "quick").touch()
    assert observer.call("verify", repo=str(repo))["isError"] is False


def transport_failure(executable, state, observer, repo):
    client = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True,
                              env={**os.environ, "XDG_STATE_HOME": str(state)})
    client.stdin.write(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
                                  "params":{"name":"verify","arguments":{"repo":str(repo)}}}) + "\n")
    client.stdin.flush()
    record = observer.running(repo)
    owned = pids(repo)
    client.stdout.close()
    client.stdin.write(json.dumps({"jsonrpc":"2.0","id":2,"method":"tools/list"}) + "\n")
    client.stdin.flush()
    client.wait(timeout=10)
    assert client.returncode == 1
    stopped(observer, record, owned)


def run(executable):
    with tempfile.TemporaryDirectory(prefix="makevn-mcp-lifecycle-") as directory:
        root = Path(directory)
        mcp = root / "makevn-mcp"
        shutil.copy2(executable, mcp)
        backend = root / "makevn"
        backend.write_text(f"#!{sys.executable}\n" + BACKEND)
        backend.chmod(0o700)
        (root / "child.py").write_text(CHILD)
        state = root / "state"
        repos = [root / f"repo-{index}" for index in range(13)]
        for repo in repos:
            repo.mkdir()
        first = Session(mcp, state)
        second = Session(mcp, state)
        try:
            tools = first.call_method("tools/list", {})["result"]["tools"]
            assert {"execution_list", "execution_status", "execution_cancel"} <= {tool["name"] for tool in tools}
            assert next(tool for tool in tools if tool["name"] == "verify")["inputSchema"]["properties"]["pr"]["type"] == "string"
            assert first.call_method("unknown/method", {})["error"]["code"] == -32601
            responsiveness_and_cancellation(first, second, repos[0], repos[1])
            pr_conflicts(first, second, repos[2], repos[3])
            notification_and_workflows(first, repos[4], repos[5])
            completion_and_forcing(first, repos[6], repos[7])
            disconnect(mcp, state, first, repos[8], mode="eof")
            disconnect(mcp, state, first, repos[9], mode="kill")
            disconnect(mcp, state, first, repos[10], mode="signal")
            disconnect(mcp, state, first, repos[11], mode="invalid")
            transport_failure(mcp, state, first, repos[12])
        finally:
            first.close()
            second.close()
        print("MCP execution lifecycle tests passed")


if __name__ == "__main__":
    run(sys.argv[1])
