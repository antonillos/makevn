"""Read-only detection of competing test JVMs; never terminate foreign processes."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import signal
import time


def query(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        return result.stdout if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def repository(path):
    root = query(["git", "-C", path, "rev-parse", "--show-toplevel"])
    common = query(["git", "-C", path, "rev-parse", "--git-common-dir"])
    if not root or not common:
        return None
    return str(Path(root.strip()).resolve()), str((Path(path) / common.strip()).resolve())


def process_cwd(pid):
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        result = query(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"])
        if result:
            return next((line[1:] for line in result.splitlines() if line.startswith("n")), None)
    return None


def test_jvms(output):
    for line in output.splitlines():
        parts = line.split(None, 8)
        if len(parts) < 9:
            continue
        pid, parent = parts[:2]
        command = " ".join(parts[7:])
        if not re.search(r"(?:^|[/\s])java(?:\s|$)", command):
            continue
        if not re.search(r"surefirebooter|surefire\.booter|failsafe", command, re.I):
            continue
        yield {"pid": int(pid), "parent_pid": int(parent), "started": " ".join(parts[2:7])}


def scan(repo):
    identity = repository(repo)
    output = query(["ps", "-axo", "pid=,ppid=,lstart=,comm=,args="])
    if identity is None or output is None:
        return {"status": "unavailable", "processes": [], "note": "Process/repository identity could not be inspected."}
    candidates, unknown = [], 0
    for process in test_jvms(output):
        cwd = process_cwd(process["pid"])
        origin = repository(cwd) if cwd else None
        if origin is None:
            unknown += 1
        elif origin[1] == identity[1]:
            process.update(checkout=origin[0], cwd=cwd)
            candidates.append(process)
    return {"status": "possible_conflict" if candidates else ("unverified" if unknown else "clear"), "processes": candidates, "unattributed_test_jvms": unknown,
            "note": "Same-repository test JVMs may share local services; this is a possible conflict, not proof of resource contention."}


def watch_command(argv):
    # Track descendant identity while the command is alive; never claim ownership
    # from checkout alone, and never terminate leftover/foreign JVMs.
    child = subprocess.Popen(argv, close_fds=False)
    owned = {child.pid}
    known_tests = {}
    old_handlers = {}
    def forward(signum, frame):
        if child.poll() is None:
            child.send_signal(signum)
    for signum in (signal.SIGINT, signal.SIGTERM):
        old_handlers[signum] = signal.signal(signum, forward)
    try:
        while child.poll() is None:
            output = query(["ps", "-axo", "pid=,ppid=,lstart=,comm=,args="]) or ""
            rows = [line.split(None, 2) for line in output.splitlines()]
            changed = True
            while changed:
                previous = len(owned)
                for row in rows:
                    if len(row) == 3 and row[0].isdigit() and row[1].isdigit() and int(row[1]) in owned:
                        owned.add(int(row[0]))
                changed = len(owned) != previous
            for process in test_jvms(output):
                if process["pid"] in owned:
                    known_tests[process["pid"]] = process["started"]
            time.sleep(0.5)
        output = query(["ps", "-axo", "pid=,ppid=,lstart=,comm=,args="]) or ""
        for process in test_jvms(output):
            if known_tests.get(process["pid"]) == process["started"]:
                print(f"WARNING: owned test JVM still alive after command exit: PID {process['pid']}; started {process['started']}. Inspect before another run; no automatic termination.", file=sys.stderr)
        return child.returncode if child.returncode >= 0 else 128 - child.returncode
    finally:
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)


def main():
    mode, repo = sys.argv[1:3]
    if mode == "watch":
        return watch_command(sys.argv[4:])
    result = scan(repo)
    if mode == "doctor":
        print(json.dumps(result))
    else:
        if result["status"] == "unavailable":
            print("Test process preflight unavailable; competing JVMs could not be ruled out.")
        for process in result["processes"]:
            print(f"Possible competing test JVM: PID {process['pid']}; started {process['started']}; checkout {process['checkout']}")
        if result["processes"]:
            print("Stop: another test JVM from this repository may share local services, including across worktrees. Ask the user to inspect and resolve it before retrying; do not kill processes automatically or start alternative infrastructure.")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
