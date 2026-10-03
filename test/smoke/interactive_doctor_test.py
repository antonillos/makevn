"""Check human compact telemetry, prompt handoff, and clean agent output."""
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time


def backend():
    time.sleep(0.5)
    if os.environ.get("TEST_PROMPT"):
        print("Confirm health URL:", file=sys.stderr, flush=True)
        answer = sys.stdin.readline().strip()
        print("answer=" + answer)
    print("Current makevn status: initialized", flush=True)


def environment(repo, agent=None, no_color=False, prompt=False):
    env = os.environ.copy()
    for key in ("MAKEVN_AGENT_OUTPUT", "MAKEVN_COMPACT_OUTPUT", "NO_COLOR"):
        env.pop(key, None)
    env["MAKEVN_INSTALL_ROOT"] = str(repo)
    env["TERM"] = "xterm-256color"
    if agent:
        env[agent] = "1"
    if no_color:
        env["NO_COLOR"] = "1"
    if prompt:
        env["TEST_PROMPT"] = "1"
    return env


def terminal(binary, repo, env, command="doctor", compact=True, prompt=False):
    argv = [binary, "--repo", str(repo), command]
    if compact:
        argv.append("--compact")
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(binary, argv, env)
    output = bytearray()
    answered = False
    deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
                if prompt and not answered and b"Confirm health URL:" in output:
                    os.write(fd, b"http://localhost/health\n")
                    answered = True
        else:
            raise TimeoutError(output[-1000:])
        _, status = os.waitpid(pid, 0)
        assert os.waitstatus_to_exitcode(status) == 0, output
        if prompt:
            assert answered and b"answer=http://localhost/health" in output, output
        return bytes(output)
    finally:
        os.close(fd)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def verify(binary):
    with tempfile.TemporaryDirectory(prefix="makevn-interactive-doctor-") as folder:
        repo = Path(folder)
        script = repo / "libexec/makevn/backend.sh"
        script.parent.mkdir(parents=True)
        common = Path(__file__).resolve().parents[2] / "libexec/makevn/common.sh"
        script.write_text('#!/usr/bin/env bash\nif [[ "${TEST_PROMPT:-}" == 1 ]]; then\n' +
                          '  source "' + str(common) + '"\n  makevn_pause_frontend_for_prompt\nfi\n' +
                          'exec "' + sys.executable + '" "' +
                          str(Path(__file__).resolve()) + '" --backend "$@"\n')
        human = terminal(binary, repo, environment(repo))
        assert b"Working for" in human and b"\x1b[32mok\x1b[0m" in human, human
        assert b"Current makevn status: initialized" in human, human
        init = terminal(binary, repo, environment(repo), command="init")
        assert b"Working for" in init and b"\x1b[32mok\x1b[0m" in init, init
        for mode in ("MAKEVN_AGENT_OUTPUT", "MAKEVN_COMPACT_OUTPUT"):
            agent = terminal(binary, repo, environment(repo, agent=mode))
            assert b"\x1b" not in agent and b"Working for" not in agent, agent
            assert b"[ok]" in agent, agent
        plain = subprocess.run([binary, "--repo", str(repo), "doctor", "--compact"],
                               env=environment(repo), capture_output=True, check=True).stdout
        assert b"\x1b" not in plain and b"Working for" not in plain, plain
        no_color = terminal(binary, repo, environment(repo, no_color=True))
        assert b"\x1b[32m" not in no_color and b"[ok]" in no_color, no_color
        terminal(binary, repo, environment(repo, prompt=True), compact=False, prompt=True)
    print("Interactive doctor tests passed")


def verify_real_doctor(binary):
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="makevn-real-doctor-dashboard-") as folder:
        repo = Path(folder)
        (repo / "pom.xml").write_text("<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId><artifactId>x</artifactId><version>1</version></project>\n")
        subprocess.run([str(root / "bin/makevn"), "--repo", str(repo), "init"], check=True, capture_output=True)
        env = environment(root)
        human = terminal(binary, repo, env, compact=False)
        assert b"Working for" in human and b"Worked  for" in human, human
        for phase in (b"Inspecting repository layout", b"Refreshing persisted profile",
                      b"Scanning workflow and Maven signals", b"Resolving Docker compose files",
                      b"Resolving Java homes", b"Reporting repository analysis"):
            assert phase in human, (phase, human)
        for detail in (b"Repo root:", b"Java Maven repo: yes", b"Current makevn status:"):
            assert detail in human, (detail, human)
        assert b"makevn doctor | Working for" not in human, human
        compact = terminal(binary, repo, env)
        assert b"Current makevn status:" in compact and b"Repo root:" not in compact, compact
        agent = subprocess.run([binary, "--repo", str(repo), "doctor", "--compact"],
                               env=environment(root, agent="MAKEVN_AGENT_OUTPUT"), capture_output=True, check=True).stdout
        assert b"\x1b" not in agent and b"Working for" not in agent and b"Worked  for" not in agent, agent
        assert b"Inspecting repository layout" not in agent, agent
    print("Real doctor dashboard tests passed")


if __name__ == "__main__":
    if sys.argv[1] == "--backend":
        backend()
    else:
        binary = str(Path(sys.argv[1]).resolve())
        verify(binary)
        verify_real_doctor(binary)
