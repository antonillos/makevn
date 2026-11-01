"""Interactive doctor persists a compatible JDK choice without running Maven."""
import os
import pty
import select
import signal
import sys
import time
from pathlib import Path

cli, repo, expected = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execv('/bin/bash', ['bash', cli, '--repo', repo, 'doctor'])
output = b''
answered = False
status = None
reaped = False
try:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            if b'Enter number' in output and not answered:
                os.write(fd, b'0\n2\n')
                answered = True
        done, child_status = os.waitpid(pid, os.WNOHANG)
        if done:
            status = child_status
            reaped = True
            break
    else:
        raise AssertionError('Interactive doctor timed out: ' + output.decode(errors='replace'))
    if status is None or not os.WIFEXITED(status):
        _, status = os.waitpid(pid, 0)
        reaped = True
    assert answered and os.waitstatus_to_exitcode(status) == 0, output
    config = (Path(repo) / '.makevn/config').read_text()
    assert f'MAKEVN_CODE_JAVA_HOME={expected}' in config, config
finally:
    os.close(fd)
    if not reaped:
        try:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
print('Interactive JDK choice passed')
