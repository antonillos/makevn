"""Exercise generated-source cleanup through the installed MCP and real backend."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

from mcp_client import request

MCP = Path(sys.argv[1]).resolve()
CLI = MCP.with_name("makevn")

with tempfile.TemporaryDirectory(prefix="makevn-generated-cleanup-") as tmp:
    repo = Path(tmp)
    fake_bin = repo / "fake-bin"
    fake_bin.mkdir()
    jdk = repo / "jdk"
    (jdk / "bin").mkdir(parents=True)
    java = jdk / "bin/java"
    java.write_text('#!/bin/sh\necho \'openjdk version "21.0.10"\' >&2\n')
    java.chmod(0o755)
    maven = fake_bin / "mvn"
    maven.write_text(
        '#!/bin/sh\nif [ "$1" = "-version" ] || [ "$1" = "--version" ]; then\n'
        'echo "Apache Maven 3.9.14"; exit 0; fi\n'
        'printf "%s\\n" "$@" >> "$MAKEVN_TEST_ARGS"\n'
        'exit "${MAKEVN_TEST_CLEAN_EXIT:-0}"\n')
    maven.chmod(0o755)
    (repo / "pom.xml").write_text(
        '<project><modelVersion>4.0.0</modelVersion><groupId>test</groupId>'
        '<artifactId>cleanup</artifactId><version>1</version><build><plugins>'
        '<plugin><artifactId>avro-maven-plugin</artifactId></plugin>'
        '</plugins></build></project>')
    (repo / ".makevn").mkdir()
    (repo / ".makevn/config").write_text(f'MAKEVN_CODE_JAVA_HOME="{jdk}"\n')
    env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}",
           "MAKEVN_TEST_ARGS": str(repo / "maven-args"), "PYTHONDONTWRITEBYTECODE": "1"}

    def call(name, **arguments):
        response = request(MCP, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                "params": {"name": name, "arguments": {
                                    "repo": str(repo), **arguments}}})
        return response["result"]["structuredContent"]

    with patch.dict(os.environ, env, clear=True):
        assert call("doctor")["exitCode"] == 0
        assert call("init")["exitCode"] == 0
        tools = request(MCP, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})["result"]["tools"]
        assert [tool["name"] for tool in tools if "clean-generated-contract-targets" in
                tool["inputSchema"]["properties"]] == ["clean"]
        stale = repo / "target/avro/old.java"
        stale.parent.mkdir(parents=True)
        stale.write_text("old generated source")
        # Fake Maven deliberately leaves target intact, isolating MakeVN's cleanup.
        assert call("clean")["exitCode"] == 0
        assert stale.exists()
        result = call("clean", **{"clean-generated-contract-targets": True})
        assert result["exitCode"] == 0, result
        assert not stale.exists(), result
        assert "Retry the original test" in result["nextSuggestion"]
        stale.parent.mkdir(parents=True)
        stale.write_text("preserve on Maven failure")
        with patch.dict(os.environ, {"MAKEVN_TEST_CLEAN_EXIT": "23"}):
            result = call("clean", **{"clean-generated-contract-targets": True})
        assert result["exitCode"] == 23, result
        assert stale.exists()
        assert result["logPaths"]
        assert "logPaths" in result["nextSuggestion"]
        assert "only to clean" in result["nextSuggestion"]
        for command in ("test", "verify", "verify-changes"):
            result = subprocess.run([str(CLI), "--repo", str(repo), command,
                                     "--clean-generated-contract-targets"],
                                    capture_output=True, text=True)
            assert result.returncode != 0
            assert "only supported by clean" in result.stdout + result.stderr
        assert (repo / "maven-args").read_text().splitlines().count("clean") == 3
print("Generated-contract MCP recovery tests passed")
