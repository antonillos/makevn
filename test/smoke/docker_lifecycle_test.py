"""Exercise volume-preserving startup and scoped resets through CLI and MCP."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from mcp_client import request

ROOT = Path(__file__).resolve().parents[2]
CLI = str(Path(sys.argv[1]).resolve()) if len(sys.argv) > 1 else str(ROOT / "bin/makevn")
MCP = str(Path(sys.argv[2]).resolve()) if len(sys.argv) > 2 else None

FAKE_DOCKER = r'''import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
repo = Path(os.environ["MAKEVN_TEST_REPO"])
if Path(sys.argv[0]).name == "docker":
    if args[:2] == ["compose", "version"]:
        sys.exit(0)
    if args[:1] != ["compose"]:
        with (repo / "engine.jsonl").open("a") as stream:
            stream.write(json.dumps(args) + "\n")
        sys.exit(0)
    args = args[1:]
with (repo / "compose.jsonl").open("a") as stream:
    stream.write(json.dumps(args) + "\n")
if "config" in args:
    print(json.dumps({"services": {"db": {"image": "fixture"}}}))
    sys.exit(0)
action = next((item for item in args if item in ("up", "down")), None)
if action is None:
    sys.exit(0)
if action == os.environ.get("MAKEVN_TEST_FAIL_ACTION"):
    print("simulated compose failure", file=sys.stderr)
    sys.exit(23)
kind = "karate" if "/e2e/karate/" in args[args.index("-f") + 1] else "boot"
volume = repo / (kind + ".data")
if action == "down" and "-v" in args:
    volume.unlink(missing_ok=True)
if action == "up" and not volume.exists():
    volume.write_text("fresh")
'''


class DockerLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="makevn-lifecycle-")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.bin = self.repo / "fake-bin"
        self.bin.mkdir()
        for name in ("docker", "docker-compose"):
            binary = self.bin / name
            binary.write_text(f"#!{sys.executable}\n" + FAKE_DOCKER)
            binary.chmod(0o755)
        (self.bin / "python3").symlink_to(sys.executable)
        self.env = {**os.environ, "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                    "MAKEVN_TEST_REPO": str(self.repo), "MAKEVN_INSTALL_ROOT": str(ROOT),
                    "PYTHONDONTWRITEBYTECODE": "1"}
        for variable in ("PROFILE", "MAKEVN_TEST_FAIL_ACTION", "MAKEVN_COMPOSE_FILE",
                         "MAKEVN_E2E_COMPOSE_FILE"):
            self.env.pop(variable, None)
        (self.repo / "pom.xml").write_text(
            "<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId>"
            "<artifactId>app</artifactId><version>1</version></project>")
        for folder in ("code/boot/src/test/resources/compose", "e2e/karate/src/test/resources/compose"):
            compose = self.repo / folder
            compose.mkdir(parents=True)
            (compose / "docker-compose.yml").write_text("services:\n  db:\n    image: fixture\n")
            (compose / "docker-compose.override.yml").write_text("services:\n  db:\n    environment:\n      TEST: yes\n")
        self.cli("doctor", "--compact")
        self.cli("init")
        self.seed_volumes()
        self.clear_logs()

    def cli(self, command, *arguments, success=True):
        result = subprocess.run([CLI, "--repo", str(self.repo), command, *arguments],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def mcp(self, command, success=True):
        from unittest.mock import patch
        with patch.dict(os.environ, self.env, clear=True):
            result = request(MCP, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": {"name": command.replace("-", "_"),
                                              "arguments": {"repo": str(self.repo)}}})["result"]
        self.assertEqual(result["isError"], not success, result)
        return result["structuredContent"]

    def seed_volumes(self):
        for kind in ("boot", "karate", "unrelated"):
            (self.repo / f"{kind}.data").write_text(f"saved-{kind}")

    def clear_logs(self):
        for name in ("compose.jsonl", "engine.jsonl"):
            (self.repo / name).write_text("")

    def records(self):
        return [json.loads(line) for line in (self.repo / "compose.jsonl").read_text().splitlines()]

    def test_up_and_down_preserve_all_volumes(self):
        for interface in ([self.cli, self.mcp] if MCP else [self.cli]):
            for prefix in ("docker", "karate-docker"):
                with self.subTest(interface=interface.__name__, prefix=prefix):
                    self.clear_logs()
                    interface(prefix + "-up")
                    interface(prefix + "-up")
                    interface(prefix + "-down")
                    self.assertEqual([args[-2:] for args in self.records()[:2]],
                                     [["up", "--detach"], ["up", "--detach"]])
                    self.assertEqual(len(self.records()), 3)
                    self.assertEqual(self.records()[-1][-1], "down")
                    self.assertNotIn("-v", self.records()[-1])
                    for kind in ("boot", "karate", "unrelated"):
                        self.assertEqual((self.repo / f"{kind}.data").read_text(), f"saved-{kind}")
                    self.assertEqual((self.repo / "engine.jsonl").read_text(), "")

    def test_reset_deletes_only_selected_project_data(self):
        for interface in ([self.cli, self.mcp] if MCP else [self.cli]):
            for kind, prefix in (("boot", "docker"), ("karate", "karate-docker")):
                with self.subTest(interface=interface.__name__, kind=kind):
                    self.seed_volumes()
                    self.clear_logs()
                    interface(prefix + "-reset")
                    self.assertEqual(len(self.records()), 2)
                    self.assertEqual(self.records()[0][-3:], ["down", "-v", "--remove-orphans"])
                    self.assertEqual(self.records()[1][-2:], ["up", "--detach"])
                    self.assertEqual(self.records()[0][:-3], self.records()[1][:-2])
                    self.assertEqual(self.records()[0].count("-f"), 2)
                    for volume in ("boot", "karate", "unrelated"):
                        expected = "fresh" if volume == kind else f"saved-{volume}"
                        self.assertEqual((self.repo / f"{volume}.data").read_text(), expected)
                    self.assertEqual((self.repo / "engine.jsonl").read_text(), "")

    def test_failed_reset_teardown_never_starts_services(self):
        self.env["MAKEVN_TEST_FAIL_ACTION"] = "down"
        for interface in ([self.cli, self.mcp] if MCP else [self.cli]):
            for prefix in ("docker", "karate-docker"):
                self.clear_logs()
                interface(prefix + "-reset", success=False)
                self.assertEqual(len(self.records()), 1)
                self.assertEqual(self.records()[0][-3:], ["down", "-v", "--remove-orphans"])
                self.assertEqual((self.repo / "boot.data").read_text(), "saved-boot")
                self.assertEqual((self.repo / "karate.data").read_text(), "saved-karate")

    def test_start_failure_is_reported_and_preserves_data(self):
        self.env["MAKEVN_TEST_FAIL_ACTION"] = "up"
        for prefix in ("docker", "karate-docker"):
            self.clear_logs()
            self.cli(prefix + "-up", success=False)
            self.assertEqual(len(self.records()), 1)
            self.assertEqual(self.records()[0][-2:], ["up", "--detach"])
        self.assertEqual((self.repo / "boot.data").read_text(), "saved-boot")
        self.assertEqual((self.repo / "karate.data").read_text(), "saved-karate")

    def test_compose_v2_and_karate_profile_are_preserved(self):
        (self.bin / "docker-compose").unlink()
        self.env["PROFILE"] = "local"
        for action in ("up", "down", "reset"):
            self.clear_logs()
            self.cli("karate-docker-" + action)
            for arguments in self.records():
                self.assertEqual(arguments[arguments.index("--profile") + 1], "local")
            self.assertEqual((self.repo / "engine.jsonl").read_text(), "")

    def test_unknown_reset_options_do_not_touch_services(self):
        for prefix in ("docker", "karate-docker"):
            self.cli(prefix + "-reset", "--unknown", success=False)
        self.assertEqual(self.records(), [])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
