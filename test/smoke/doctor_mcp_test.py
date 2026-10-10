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
        data = result["structuredContent"]
        output = data["untrustedData"]["output"]
        if tool == "doctor":
            if "interactive setup required:" in output:
                assert "launch the CLI command makevn doctor" in data["nextSuggestion"]
                assert "Do NOT use MCP doctor again" in data["nextSuggestion"]
            elif "force: false" in output:
                assert data["nextSuggestion"] == "Run makevn init (MCP: init with force: false) before verification."
            elif "force: true" in output:
                assert "init with force: true" in data["nextSuggestion"]
            elif "Repository support status: unsupported" in output:
                assert "do not run init" in data["nextSuggestion"]
            else:
                assert "without running init" in data["nextSuggestion"]
        assert json.loads(result["content"][0]["text"]) == result["structuredContent"]
        assert result["isError"] is False
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
    for candidate in ["a", "b"]:
        compose = repo / candidate / "docker-compose.yml"
        compose.parent.mkdir()
        compose.write_text("services: {}\n")
    assert "interactive setup required:" in call("doctor")
    config = repo / ".makevn/config"
    config.write_text(config.read_text() + 'MAKEVN_RUN_CMD="custom"\n')
    before = config.read_text()
    call("init", **{"reset-config": True, "dry-run": True})
    assert config.read_text() == before
    call("init", **{"reset-config": True})
    assert 'MAKEVN_RUN_CMD=""' in config.read_text()
    backups = list((repo / ".makevn").glob("config-backup.*/config"))
    assert len(backups) == 1 and backups[0].read_text() == before
with tempfile.TemporaryDirectory() as tmp:
    assert "Repository support status: unsupported" in call("doctor")
print("Doctor MCP recommendation tests passed")
