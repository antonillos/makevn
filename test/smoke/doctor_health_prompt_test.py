"""PTY driver for doctor health configuration regression tests."""
import json
import fcntl
import os
import pty
import select
import signal
import sys
import struct
import termios
import time

cli, repo, output_file, responses_json = sys.argv[1:5]
responses = json.loads(responses_json)
pid, fd = pty.fork()
if pid == 0:
    os.environ["NO_COLOR"] = "1"
    os.execv(cli, [cli, "--repo", repo, "doctor"])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 200, 0, 0))
output = bytearray()
next_response = 0
scan_from = 0
started = time.monotonic()
try:
    while True:
        readable, _, _ = select.select([fd], [], [], 0.1)
        if readable:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
            if next_response < len(responses):
                token, response = responses[next_response]
                found = output.find(token.encode(), scan_from)
                if found >= 0:
                    payload = b"\x15" + response.encode() if response else b""
                    os.write(fd, payload + b"\n")
                    scan_from = len(output)
                    next_response += 1
        if time.monotonic() - started > 45:
            raise TimeoutError("doctor prompt did not finish: " + output[-3000:].decode(errors="replace"))
    _, status = os.waitpid(pid, 0)
    assert next_response == len(responses), output.decode(errors="replace")
    raise SystemExit(os.waitstatus_to_exitcode(status))
finally:
    with open(output_file, "wb") as stream:
        stream.write(output)
    os.close(fd)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
