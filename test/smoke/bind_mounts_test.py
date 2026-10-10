"""Read-only mount visibility diagnostics distinguish failures from unknown probes."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("bind_mounts", root / "libexec/makevn/docker/bind_mounts.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class BindMountTests(unittest.TestCase):
    def setUp(self):
        availability = patch.object(module.shutil, "which", return_value="/fixture/docker-compose")
        availability.start()
        self.addCleanup(availability.stop)

    def test_compose_resolution_matches_shell_resolver(self):
        with patch.object(module.shutil, "which", return_value="/fixture/docker-compose"), patch.object(module, "query") as probe:
            self.assertEqual(module.compose_command("/tmp", "/compose", ""), ["docker-compose", "-f", "/compose"])
            probe.assert_not_called()
        with patch.object(module.shutil, "which", return_value=None):
            with patch.object(module, "query", return_value=subprocess.CompletedProcess([], 0, "version", "")) as probe:
                self.assertEqual(module.compose_command("/tmp", "/compose", ""), ["docker", "compose", "-f", "/compose"])
                probe.assert_called_once_with(["docker", "compose", "version"], "/tmp")
            with patch.object(module, "query", return_value=subprocess.CompletedProcess([], 1, "", "plugin missing")):
                self.assertIsNone(module.compose_command("/tmp", "/compose", ""))

    def test_visible_missing_unknown_and_no_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            compose = Path(tmp) / "compose.yml"
            compose.write_text("services: {}")
            source = Path(tmp) / "bootstrap"
            source.mkdir()
            (source / "data.json").write_text("secret not read")
            config = {"services": {"db": {"volumes": [{"type": "bind", "source": str(source), "target": "/tmp/data"}, {"type": "volume", "source": "data", "target": "/data"}]}}}
            for code, stderr, expected in [(0, "", "visible"), (1, "", "error"), (127, "", "unverified"), (1, "daemon unavailable", "unverified")]:
                commands = []
                def query(argv, cwd):
                    commands.append(argv)
                    if "config" in argv:
                        return subprocess.CompletedProcess(argv, 0, json.dumps(config), "")
                    if "ps" in argv:
                        return subprocess.CompletedProcess(argv, 0, "container-id\n", "")
                    return subprocess.CompletedProcess(argv, code, "", stderr)
                with patch.object(module, "query", side_effect=query):
                    result = module.diagnostics("required", tmp, str(compose))
                    self.assertEqual(result["checks"][0]["status"], expected)
                    self.assertEqual(len(result["checks"]), 1)
                    self.assertTrue(all(not any(x in c for x in ["run", "up", "rm", "restart"]) for c in commands))
                    self.assertIn(["docker", "exec", "container-id", "test", "-e", "/tmp/data/data.json"], commands)
                    self.assertEqual((source / "data.json").read_text(), "secret not read")
            with patch.object(module, "query", return_value=subprocess.CompletedProcess([], 0, json.dumps(config), "")):
                self.assertEqual(module.diagnostics("doctor", tmp, str(compose))["checks"][0]["status"], "unverified")
            (source / "data.json").unlink()
            with patch.object(module, "query", return_value=subprocess.CompletedProcess([], 0, json.dumps(config), "")):
                self.assertEqual(module.diagnostics("required", tmp, str(compose))["checks"][0]["status"], "empty_source")
            source.rmdir()
            with patch.object(module, "query", return_value=subprocess.CompletedProcess([], 0, json.dumps(config), "")):
                self.assertEqual(module.diagnostics("doctor", tmp, str(compose))["checks"][0]["status"], "warning")

    def test_unavailable_config_is_not_successful_verification(self):
        with tempfile.NamedTemporaryFile() as compose:
            with patch.object(module, "query", return_value=None):
                self.assertEqual(module.diagnostics("required", "/tmp", compose.name)["status"], "unavailable")
            with patch.object(module, "query", return_value=subprocess.CompletedProcess([], 0, "not json", "")):
                self.assertEqual(module.diagnostics("doctor", "/tmp", compose.name)["status"], "unavailable")

if __name__ == "__main__":
    unittest.main()
