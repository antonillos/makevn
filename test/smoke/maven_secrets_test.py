"""Native-store resolution tests using fake credentials and fake Maven only."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "libexec/makevn/common/maven_secrets.py"
spec = importlib.util.spec_from_file_location("maven_secrets", SCRIPT)
secrets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(secrets)


class MavenSecretsTest(unittest.TestCase):
    def test_store_value_reaches_child_without_modifying_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "mvnw"
            executable.write_text('#!/bin/sh\n[ "$MAKEVN_TEST_SECRET" = "fake-native-value" ]\n')
            executable.chmod(0o755)
            with patch.dict(os.environ, {}, clear=True), patch.object(secrets, "references", return_value=["MAKEVN_TEST_SECRET"]), \
                    patch.object(secrets, "lookup", return_value="fake-native-value") as lookup:
                self.assertEqual(secrets.run([str(executable)]), 0)
                lookup.assert_called_once_with("MAKEVN_TEST_SECRET")
                self.assertNotIn("MAKEVN_TEST_SECRET", os.environ)

    def test_missing_secret_stops_before_maven(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(secrets, "references", return_value=["TOKEN"]), \
                patch.object(secrets, "lookup", side_effect=secrets.SecretUnavailable("TOKEN missing")), \
                patch.object(subprocess, "Popen") as child:
            with self.assertRaises(secrets.SecretUnavailable):
                secrets.run(["mvn"])
            child.assert_not_called()

    def test_comments_are_not_secret_requests(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = Path(directory) / "settings.xml"
            settings.write_text('<settings><!-- ${env.IGNORED} --><password>${env.TOKEN}</password></settings>')
            self.assertEqual(secrets.references([settings]), ["TOKEN"])

    def test_explicit_settings_override_project_and_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".mvn").mkdir()
            (root / ".mvn/maven.config").write_text('--settings\nproject.xml\n')
            paths = secrets.settings_paths(["mvn", "--settings", "selected.xml", "-gs=global.xml"],
                                           root, {"MAVEN_ARGS": "--settings environment.xml"})
            self.assertEqual(paths, [root / "selected.xml", root / "global.xml"])

    def test_native_command_and_failure_do_not_disclose_output(self):
        response = subprocess.CompletedProcess([], 1, b"fake-sensitive-output", b"fake-error")
        with patch.object(sys, "platform", "darwin"), patch.object(subprocess, "run", return_value=response) as call:
            with self.assertRaises(secrets.SecretUnavailable) as error:
                secrets.lookup("TOKEN")
            self.assertIn("TOKEN", str(error.exception))
            self.assertNotIn("fake-sensitive", str(error.exception))
            self.assertEqual(call.call_args.args[0][2:4], ["-a", "TOKEN"])

    def test_user_selected_service_is_used(self):
        response = subprocess.CompletedProcess([], 0, b"test-value\n", b"")
        with patch.object(sys, "platform", "darwin"), patch.object(secrets, "SERVICE", "personal-service"), \
                patch.object(subprocess, "run", return_value=response) as call:
            self.assertEqual(secrets.lookup("TOKEN"), "test-value")
            self.assertIn("personal-service", call.call_args.args[0])

    def test_configured_service_falls_back_to_default(self):
        missing = subprocess.CompletedProcess([], 1, b"", b"duplicate or missing")
        found = subprocess.CompletedProcess([], 0, b"test-value\n", b"")
        with patch.object(sys, "platform", "darwin"), patch.object(secrets, "SERVICE", "personal-service"), \
                patch.object(subprocess, "run", side_effect=[missing, found]) as call:
            self.assertEqual(secrets.lookup("TOKEN"), "test-value")
            self.assertEqual(len(call.call_args_list), 2)
            self.assertIn(secrets.DEFAULT_SERVICE, call.call_args_list[-1].args[0])

    def test_inherited_value_is_redacted_and_http_failure_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "settings.xml").write_text('<settings><password>${env.TEST_TOKEN}</password></settings>')
            executable = root / "mvnw"
            executable.write_text('#!/bin/sh\nprintf "401 auth: %s\\n403 forbidden\\n" "$TEST_TOKEN"\nexit 7\n')
            executable.chmod(0o755)
            environment = os.environ | {"TEST_TOKEN": "test-only-secret"}
            result = subprocess.run([sys.executable, str(SCRIPT), str(executable), "-s", "settings.xml"],
                                    cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 7)
            self.assertNotIn("test-only-secret", result.stdout + result.stderr)
            self.assertIn("401 auth: [REDACTED]", result.stdout)
            self.assertIn("403 forbidden", result.stdout)


if __name__ == "__main__":
    unittest.main()
