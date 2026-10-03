"""Exercise explicit init recommendations through the real MCP response."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

mcp = sys.argv[1]
with tempfile.TemporaryDirectory() as tmp:
    repo = Path(tmp)
    (repo / "pom.xml").write_text(
        "<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId>"
        "<artifactId>x</artifactId><version>1</version></project>\n"
    )

    def call(tool, **arguments):
        request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                   "params": {"name": tool, "arguments": {"repo": tmp, **arguments}}}
        response = subprocess.run([mcp], input=json.dumps(request) + "\n",
                                  text=True, capture_output=True, check=True)
        result = json.loads(response.stdout)["result"]
        output = "\n".join(item["text"] for item in result["content"])
        assert "\x1b" not in output, output
        assert "Working for" not in output, output
        return output

    assert "Init recommendation: makevn_init (force: false)" in call("doctor")
    call("init")
    assert "Init recommendation: none (already up to date)" in call("doctor")
    manifest = repo / ".makevn/manifest"
    manifest.write_text("\n".join(
        "makevn_version=old" if line.startswith("makevn_version=") else line
        for line in manifest.read_text().splitlines()) + "\n")
    assert "Init recommendation: makevn_init (force: true)" in call("doctor")
    call("init", force=True)
    (repo / ".makevn/state.json").unlink()
    assert "Init recommendation: makevn_init (force: true)" in call("doctor")
print("Doctor MCP recommendation tests passed")
