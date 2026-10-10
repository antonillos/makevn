"""Reset belongs to interactive doctor; initialization and logs survive."""
import os
import pty
import subprocess
import sys
import tempfile
from pathlib import Path

cli = sys.argv[1]
with tempfile.TemporaryDirectory() as tmp:
    repo = Path(tmp)
    (repo / "pom.xml").write_text("<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId><artifactId>x</artifactId><version>1</version></project>")
    def run(*args):
        return subprocess.run([cli, "--repo", tmp, *args], capture_output=True, text=True)
    assert run("doctor", "--compact").returncode == 0
    assert run("init").returncode == 0
    config = repo / ".makevn/config"
    config.write_text(config.read_text() + '\nMAKEVN_RUN_CMD="custom"\nMAKEVN_APP_HEALTH_URL="http://localhost:9999/health"\n')
    before = config.read_text()
    manifest = (repo / ".makevn/manifest").read_bytes()
    (repo / ".makevn/logs/sentinel").write_text("keep")
    for args in [("init", "--reset-config"), ("doctor", "--reset-config"), ("doctor", "--compact", "--reset-config")]:
        assert run(*args).returncode != 0
        assert config.read_text() == before
        assert not list((repo / ".makevn").glob("config-backup.*"))
    assert run("init", "--force").returncode == 0
    assert config.read_text() == before
    master, slave = pty.openpty()
    try:
        result = subprocess.run([cli, "--repo", tmp, "doctor", "--reset-config"], stdin=slave, stderr=slave, stdout=subprocess.PIPE, timeout=60, env={**os.environ, "NO_COLOR": "1"})
        assert result.returncode == 0, result.stdout
        assert b"Configuration backup:" in result.stdout, result.stdout
    finally:
        os.close(slave)
        os.close(master)
    backups = list((repo / ".makevn").glob("config-backup.*/config"))
    assert len(backups) == 1 and backups[0].read_text() == before
    assert str(backups[0].parent).encode() in result.stdout, result.stdout
    assert 'MAKEVN_RUN_CMD=""' in config.read_text()
    assert "MAKEVN_APP_HEALTH_URL" not in config.read_text()
    assert (repo / ".makevn/manifest").read_bytes() == manifest
    assert (repo / ".makevn/logs/sentinel").read_text() == "keep"
    assert "next: makevn init" not in run("doctor", "--compact").stdout
print("Interactive doctor reset tests passed")
