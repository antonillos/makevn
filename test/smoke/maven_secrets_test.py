"""Native-store resolution tests using fake credentials and fake Maven only."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "libexec/makevn/common/maven_secrets.py"
spec = importlib.util.spec_from_file_location("maven_secrets", SCRIPT)
secrets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(secrets)


class MavenSecretsTest(unittest.TestCase):
    def test_user_account_and_variable_select_keychain_entry(self):
        response = subprocess.CompletedProcess([], 0, b"fake-value\n", b"")
        with patch.object(sys, "platform", "darwin"), \
                patch.object(secrets.pwd, "getpwuid", return_value=SimpleNamespace(pw_name="local-user")), \
                patch.object(secrets, "keychain_match_count", return_value=1), \
                patch.object(subprocess, "run", return_value=response) as call:
            self.assertEqual(secrets.lookup_user_account("TOKEN"), "fake-value")
            self.assertEqual(call.call_args.args[0][-5:], ["-a", "local-user", "-s", "TOKEN", "-w"])

    def test_ambiguous_keychain_does_not_read_any_password(self):
        with patch.object(sys, "platform", "darwin"), \
                patch.object(secrets.pwd, "getpwuid", return_value=SimpleNamespace(pw_name="local-user")), \
                patch.object(secrets, "keychain_match_count", return_value=2), \
                patch.object(secrets, "run_secret_lookup") as lookup:
            with self.assertRaises(secrets.SecretUnavailable):
                secrets.lookup_user_account("TOKEN")
            lookup.assert_not_called()

    def test_login_shell_reads_only_requested_exported_values(self):
        with tempfile.TemporaryDirectory() as directory:
            shell = Path(directory) / "shell"
            shell.write_text('#!/bin/sh\nexport MAKEVN_TEST_TOKEN=shell-only-value\nprintf banner\nexec /bin/sh "$@"\n')
            shell.chmod(0o755)
            with patch.object(secrets.pwd, "getpwuid", return_value=SimpleNamespace(pw_shell=str(shell))), \
                    patch.dict(os.environ, {"HOME": directory}, clear=True):
                self.assertEqual(secrets.shell_values(["MAKEVN_TEST_TOKEN"]),
                                 {"MAKEVN_TEST_TOKEN": "shell-only-value"})

    def test_store_value_reaches_child_without_modifying_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "mvnw"
            executable.write_text('#!/bin/sh\n[ "$MAKEVN_TEST_SECRET" = "fake-native-value" ]\n')
            executable.chmod(0o755)
            with patch.dict(os.environ, {}, clear=True), patch.object(secrets, "references", return_value=["MAKEVN_TEST_SECRET"]), \
                    patch.object(secrets, "lookup_user_account", return_value=None), \
                    patch.object(secrets, "shell_values", return_value={}), \
                    patch.object(secrets, "lookup", return_value="fake-native-value") as lookup:
                self.assertEqual(secrets.run([str(executable)]), 0)
                lookup.assert_called_once_with("MAKEVN_TEST_SECRET")
                self.assertNotIn("MAKEVN_TEST_SECRET", os.environ)

    def test_missing_secret_stops_before_maven(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(secrets, "references", return_value=["TOKEN"]), \
                patch.object(secrets, "lookup_user_account", return_value=None), \
                patch.object(secrets, "shell_values", return_value={}), \
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

    def test_maven_39_config_treats_each_line_as_one_argument(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "maven.config"
            config.write_text("-Dlabel=it's-valid\n--settings\nsettings with spaces.xml\n")
            self.assertEqual(secrets.maven_config_arguments(config, (3, 9, 10)),
                             ["-Dlabel=it's-valid", "--settings", "settings with spaces.xml"])

    def test_legacy_maven_config_keeps_shell_style_argument_splitting(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "maven.config"
            config.write_text("--settings legacy.xml -Dlabel='quoted value'\n")
            self.assertEqual(secrets.maven_config_arguments(config, (3, 8, 8)),
                             ["--settings", "legacy.xml", "-Dlabel=quoted value"])

    def test_nested_selected_pom_finds_its_maven_config(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            nested = root / "code"
            (nested / ".mvn").mkdir(parents=True)
            (root / ".mvn").mkdir()
            (nested / ".mvn/maven.config").write_text("--settings\nnested-settings.xml\n")
            (root / ".mvn/maven.config").write_text("--settings\nroot.xml\n")
            paths = secrets.settings_paths(["mvn", "-f", "code/pom.xml"], root, {})
            self.assertEqual(paths[0], root / "nested-settings.xml")

    def test_selected_maven_installation_overrides_inherited_maven_home(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selected = root / "selected-maven"
            inherited = root / "inherited-maven"
            (selected / "bin").mkdir(parents=True)
            (selected / "lib").mkdir()
            (selected / "conf").mkdir()
            (inherited / "conf").mkdir(parents=True)
            executable = selected / "bin/mvn"
            executable.write_text("#!/bin/sh\n")
            executable.chmod(0o755)
            (selected / "lib/maven-core-3.9.10.jar").touch()
            (selected / "conf/settings.xml").touch()
            (inherited / "conf/settings.xml").write_text("stale")
            with patch.dict(os.environ, {"PATH": str(selected / "bin")}):
                paths = secrets.settings_paths([str(executable)], root, {"MAVEN_HOME": str(inherited)})
            self.assertEqual(paths[1], (selected / "conf/settings.xml").resolve())

    def test_selected_pom_can_be_given_as_long_option(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pom = root / "module/pom.xml"
            (root / "module/.mvn").mkdir(parents=True)
            (root / "module/.mvn/maven.config").write_text("--settings=module-settings.xml\n")
            paths = secrets.settings_paths(["mvn", f"--file={pom}"], root, {})
            self.assertEqual(paths[0], root / "module-settings.xml")

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
            bootstrap = 'import runpy,sys; sys.platform="test"; sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name="__main__")'
            result = subprocess.run([sys.executable, "-c", bootstrap, str(SCRIPT), str(executable), "-s", "settings.xml"],
                                    cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 7)
            self.assertNotIn("test-only-secret", result.stdout + result.stderr)
            self.assertIn("401 auth: [REDACTED]", result.stdout)
            self.assertIn("403 forbidden", result.stdout)

    def test_user_keychain_precedes_inherited_value(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "mvnw"
            executable.write_text('#!/bin/sh\n[ "$TOKEN" = "keychain-value" ]\n')
            executable.chmod(0o755)
            with patch.dict(os.environ, {"TOKEN": "inherited-value"}), \
                    patch.object(secrets, "references", return_value=["TOKEN"]), \
                    patch.object(secrets, "lookup_user_account", return_value="keychain-value"), \
                    patch.object(secrets, "shell_values", return_value={}) as shell:
                self.assertEqual(secrets.run([str(executable)]), 0)
                shell.assert_called_once_with([])

    def test_shell_fallback_is_injected_without_persisting(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "mvnw"
            executable.write_text('#!/bin/sh\n[ "$TOKEN" = "shell-value" ]\n')
            executable.chmod(0o755)
            with patch.dict(os.environ, {}, clear=True), \
                    patch.object(secrets, "references", return_value=["TOKEN"]), \
                    patch.object(secrets, "lookup_user_account", return_value=None), \
                    patch.object(secrets, "shell_values", return_value={"TOKEN": "shell-value"}):
                self.assertEqual(secrets.run([str(executable)]), 0)
                self.assertNotIn("TOKEN", os.environ)


if __name__ == "__main__":
    unittest.main()
