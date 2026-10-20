"""Complete doctor setup through real MCP stdio, with no TTY or Maven execution."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

from mcp_client import request

server = sys.argv[1]


def call(repo, name, error=False, **arguments):
    response = request(server, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                               "params": {"name": name, "arguments": {"repo": str(repo), **arguments}}})
    result = response["result"]
    assert result["isError"] is error, response
    assert json.loads(result["content"][0]["text"]) == result["structuredContent"]
    return result["structuredContent"]


def configure(repo, doctor, answers, error=False):
    return call(repo, "doctor_configure", error=error,
                setupToken=doctor["interactive_setup"]["setupToken"], answers=answers)


def questions(doctor):
    return {item["id"]: item for item in doctor["interactive_setup"]["questions"]}


with tempfile.TemporaryDirectory(prefix="makevn-doctor-chat-") as directory:
    repo = Path(directory)
    (repo / "pom.xml").write_text('<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId>'
                                  '<artifactId>app</artifactId><version>1</version><dependencies><dependency>'
                                  '<groupId>org.testcontainers</groupId><artifactId>testcontainers</artifactId>'
                                  '<version>1</version></dependency></dependencies></project>')
    source = repo / "src/main/java/Application.java"
    source.parent.mkdir(parents=True)
    source.write_text("public class Application { public static void main(String[] args) {} }")
    for candidate in ["boot-a", "boot-b", "e2e/a", "e2e/b"]:
        compose = repo / candidate / "docker-compose.yml"
        compose.parent.mkdir(parents=True)
        compose.write_text("services: {}\n")
    workflows = repo / ".github/workflows"
    workflows.mkdir(parents=True)
    for name, profiles in [("karate-a", "local"), ("karate-b", "standalone")]:
        (workflows / f"{name}.yml").write_text(
            f"jobs:\n  karate:\n    env:\n      SPRING_PROFILES_ACTIVE: {profiles}\n"
            "      LOCAL_CONTAINERS: TRUE\n    steps:\n      - run: ./mvnw verify\n")
    for variable in ["SPRING_PROFILES_ACTIVE", "LOCAL_CONTAINERS", "MAKEVN_KARATE_APP_PROFILES"]:
        os.environ.pop(variable, None)
    initial = call(repo, "doctor")
    assert initial["suggested_next_step"]["next"] == "makevn init", initial
    configure(repo, initial, {"local_containers": True}, error=True)
    assert not (repo / ".makevn/config").exists()
    call(repo, "init")
    doctor = call(repo, "doctor")
    config = repo / ".makevn/config"
    config.write_text(config.read_text() + '# Keep user settings\nCUSTOM_SETTING="preserved"\n')
    doctor = call(repo, "doctor")
    available = questions(doctor)
    assert set(available) == {"boot_compose", "e2e_compose", "app_health_url", "local_containers",
                              "karate_app_profiles"}, doctor
    assert doctor["interactive_setup"]["requires_tty"] is False
    assert "configuration is pending" in doctor["message"]
    with patch.dict(os.environ, {"SPRING_PROFILES_ACTIVE": "", "LOCAL_CONTAINERS": ""}):
        overridden = questions(call(repo, "doctor"))
        assert "local_containers" not in overridden and "karate_app_profiles" not in overridden
    before = config.read_bytes()
    for answers in [{"local_containers": True, "app_health_url": "bad"},
                    {"unknown": "x"}, {"boot_compose": "/no/such/file"}]:
        invalid = configure(repo, doctor, answers, error=True)
        assert config.read_bytes() == before
        assert questions(invalid) == available
    # Even a still-valid choice needs reconfirmation when the offered set changes.
    added = repo / "boot-c/docker-compose.yml"
    added.parent.mkdir()
    added.write_text("services: {}\n")
    stale = configure(repo, doctor, {"boot_compose": available["boot_compose"]["options"][0]}, error=True)
    assert len(questions(stale)["boot_compose"]["options"]) == 3
    assert config.read_bytes() == before
    doctor = stale
    partial = configure(repo, doctor, {"local_containers": False})
    assert "local_containers" not in questions(partial)
    assert partial["interactive_setup"]["required"] is True
    assert "app_health_url" in questions(partial)
    before = config.read_bytes()
    config.write_bytes(before + b"# changed during chat\n")
    stale = configure(repo, partial, {"app_health_url": "http://localhost/health"}, error=True)
    assert config.read_bytes() == before + b"# changed during chat\n"
    available = questions(stale)
    special_url = "http://localhost/health?value='$(touch${IFS}SENTINEL)`id`&ok=yes"
    completed = configure(repo, stale, {
        "boot_compose": available["boot_compose"]["options"][0],
        "e2e_compose": available["e2e_compose"]["options"][1],
        "app_health_url": special_url, "karate_app_profiles": "standalone,local"})
    assert completed["interactive_setup"]["status"] == "ready", completed
    assert completed["interactive_setup"]["required"] is False
    assert questions(completed) == {}
    assert questions(call(repo, "doctor")) == {}
    assert not (repo / "SENTINEL").exists()
    assert 'CUSTOM_SETTING="preserved"' in config.read_text()
    result = subprocess.run(["bash", "-c", 'source "$1"; printf "%s" "$MAKEVN_APP_HEALTH_URL"',
                             "bash", str(config)], cwd=repo, text=True, capture_output=True, check=True)
    assert result.stdout == special_url

with tempfile.TemporaryDirectory(prefix="makevn-doctor-unsupported-") as directory:
    repo = Path(directory)
    doctor = call(repo, "doctor")
    assert questions(doctor) == {}
    configure(repo, doctor, {"local_containers": True}, error=True)
    assert not (repo / ".makevn/config").exists()

print("Doctor chat configuration MCP tests passed")
