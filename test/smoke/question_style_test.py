"""Question blocks use one blank separator and the shared yellow style."""
import errno
import os
from pathlib import Path
import pty
import subprocess

root = Path(__file__).resolve().parents[2]
script = 'source "$1"; makevn_print_question "Compose question"; printf "Answer saved\\n" >&2; makevn_print_question "Health question"'
for no_color in [False, True]:
    master, slave = pty.openpty()
    env = {**os.environ, "TERM": "xterm-256color"}
    env.pop("MAKEVN_AGENT_OUTPUT", None)
    env.pop("NO_COLOR", None)
    if no_color:
        env["NO_COLOR"] = "1"
    # Keep bashcov's tracing channel separate from the terminal under coverage.
    trace_fds = ()
    if env.get("BASH_XTRACEFD"):
        trace_fd = int(env["BASH_XTRACEFD"])
        os.fstat(trace_fd)
        trace_fds = (trace_fd,)
    try:
        proc = subprocess.Popen(["bash", "-c", script, "bash", str(root / "libexec/makevn/common/ui.sh")], stdout=slave, stderr=slave, env=env, pass_fds=trace_fds)
        os.close(slave)
        slave = None
        data = b""
        while True:
            try:
                chunk = os.read(master, 4096)
                if not chunk:
                    break
                data += chunk
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
        assert proc.wait(timeout=10) == 0
        data = data.replace(b"\r\n", b"\n")
        yellow, reset = (b"", b"") if no_color else (b"\x1b[33m", b"\x1b[0m")
        assert data == b"\n" + yellow + b"Compose question" + reset + b"\nAnswer saved\n\n" + yellow + b"Health question" + reset + b"\n", data
    finally:
        if slave is not None:
            os.close(slave)
        os.close(master)
print("Question color and spacing tests passed")
