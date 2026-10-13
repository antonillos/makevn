"""Keep test clients connected until their requested MCP response arrives."""
import json
import os
import subprocess
import tempfile


def request(server, message):
    with tempfile.TemporaryDirectory(prefix="makevn-mcp-client-") as state:
        with subprocess.Popen([str(server)], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                              env={**os.environ, "XDG_STATE_HOME": state}) as client:
            client.stdin.write(json.dumps(message) + "\n")
            client.stdin.flush()
            response = client.stdout.readline()
            client.stdin.close()
            client.wait(timeout=10)
            assert client.returncode == 0, client.stderr.read()
            return json.loads(response)
