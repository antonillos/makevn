"""Local HTTP fixture for Karate readiness transport tests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
import subprocess
import threading
import time


class HealthHandler(BaseHTTPRequestHandler):
    attempts = 0

    def do_GET(self):
        if self.path == "/retry":
            type(self).attempts += 1
            status = 503 if self.attempts == 1 else 200
        elif self.path == "/hang":
            time.sleep(4)
            status = 200
        else:
            status = int(self.path.strip("/"))
        self.send_response(status)
        self.end_headers()

    def log_message(self, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), HealthHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()

def wait_for(path, timeout):
    return subprocess.run(
        ["bash", "-c",
         'source "$1/libexec/makevn/common.sh"; '
         'source "$1/libexec/makevn/commands/run.sh"; '
         'makevn_wait_app_health "$2" "$3"',
         "bash", sys.argv[1],
         f"http://127.0.0.1:{server.server_port}/{path}", str(timeout)],
        capture_output=True, text=True, timeout=10,
    )

try:
    result = wait_for("retry", 5)
    assert result.returncode == 0, result.stderr
    assert "HTTP readiness verified" in result.stdout
    for status in (301, 404, 503):
        result = wait_for(str(status), 1)
        assert result.returncode != 0
        assert "did not pass within 1s" in result.stderr
    started = time.monotonic()
    result = wait_for("hang", 1)
    assert result.returncode != 0
    assert "did not pass within 1s" in result.stderr
    assert time.monotonic() - started < 2.5
finally:
    server.shutdown()
    server.server_close()
