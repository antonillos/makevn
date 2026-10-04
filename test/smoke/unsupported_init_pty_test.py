"""Ensure init rejection remains visible in the human terminal dashboard."""
import os
from pathlib import Path
import pty
import select
import signal
import sys
import tempfile
import time

with tempfile.TemporaryDirectory(prefix="makevn-unsupported-pty-") as folder:
    repo = Path(folder)
    (repo / "Cargo.toml").write_text('[package]\nname="rust-only"\nversion="0.1.0"\n')
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["MAKEVN_INSTALL_ROOT"] = str(Path(__file__).resolve().parents[2])
        os.environ["TERM"] = "xterm-256color"
        os.environ["NO_COLOR"] = "1"
        for key in ("MAKEVN_COMPACT_OUTPUT", "MAKEVN_AGENT_OUTPUT", "CODEX_THREAD_ID", "CLAUDECODE", "CI"):
            os.environ.pop(key, None)
        os.execv(sys.argv[1], [sys.argv[1], "--repo", folder, "init"])
    output = bytearray()
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if not select.select([fd], [], [], 0.1)[0]:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        else:
            raise TimeoutError(output.decode(errors="replace"))
        _, status = os.waitpid(pid, 0)
        assert os.waitstatus_to_exitcode(status) == 1, output
        text = output.decode(errors="replace").replace('\r', '')
        # The final dashboard must retain the reason, not only a transient redraw.
        final = text[text.rfind('Worked'):]
        assert 'Cannot initialize makevn: no Maven project detected.' in final, text
        assert not (repo / '.makevn').exists()
    finally:
        os.close(fd)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
