"""Test Docker prerequisite failures and Java environment forwarding without Docker."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "libexec/makevn/docker/testcontainers.py"
spec = importlib.util.spec_from_file_location("testcontainers_runtime", HELPER)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class TestcontainersTests(unittest.TestCase):
    def test_local_context_is_forwarded_without_changing_parent(self):
        environment = {"DOCKER_CONTEXT": "local", "TESTCONTAINERS_HOST_OVERRIDE": "host"}
        with patch.object(runtime, "docker_output", side_effect=["unix:///tmp/runtime.sock", "28"]) as run:
            result = runtime.test_environment(environment)
        self.assertEqual(result["DOCKER_HOST"], "unix:///tmp/runtime.sock")
        self.assertNotIn("DOCKER_CONTEXT", result)
        self.assertEqual(result["TESTCONTAINERS_HOST_OVERRIDE"], "host")
        self.assertNotIn("DOCKER_HOST", environment)
        self.assertEqual(run.call_args_list[1].args[1], result)

    def test_current_context_is_resolved(self):
        with patch.object(runtime, "docker_output", side_effect=["local", "unix:///tmp/runtime.sock", "28"]) as run:
            runtime.test_environment({})
        self.assertEqual(run.call_args_list[0].args[0], ["context", "show"])

    def test_explicit_host_tls_and_socket_settings_are_preserved(self):
        environment = {
            "DOCKER_HOST": "tcp://engine:2376", "DOCKER_CONTEXT": "different",
            "DOCKER_TLS_VERIFY": "1", "DOCKER_CERT_PATH": "/tmp/certs",
            "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE": "/var/run/docker.sock",
        }
        with patch.object(runtime, "docker_output", return_value="28") as run:
            result = runtime.test_environment(environment)
        self.assertEqual(run.call_count, 1)
        for key, value in environment.items():
            if key != "DOCKER_CONTEXT":
                self.assertEqual(result[key], value)

    def test_remote_context_is_not_silently_translated(self):
        for endpoint in ("ssh://engine", "tcp://engine:2376", "", "<no value>"):
            with self.subTest(endpoint=endpoint), patch.object(runtime, "docker_output", return_value=endpoint):
                with self.assertRaisesRegex(RuntimeError, "Configure DOCKER_HOST"):
                    runtime.test_environment({"DOCKER_CONTEXT": "remote"})

    def test_empty_server_response_is_not_success(self):
        with patch.object(runtime, "docker_output", return_value=""):
            with self.assertRaisesRegex(RuntimeError, "no server version"):
                runtime.test_environment({"DOCKER_HOST": "unix:///tmp/runtime.sock"})

    def test_probe_is_bounded_and_preserves_docker_diagnostic(self):
        result = subprocess.CompletedProcess([], 42, "", "daemon unavailable")
        with patch.object(runtime.subprocess, "run", return_value=result) as run:
            with self.assertRaisesRegex(RuntimeError, "daemon unavailable"):
                runtime.docker_output(["info"], {})
        self.assertEqual(run.call_args.kwargs["timeout"], 15)

    def test_prerequisite_failures_do_not_exec_tests(self):
        for error in (FileNotFoundError("docker missing"), RuntimeError("daemon unavailable"),
                      subprocess.TimeoutExpired("docker", 15)):
            with self.subTest(error=error), patch.object(runtime, "test_environment", side_effect=error), \
                    patch.object(runtime.os, "execvpe") as execute:
                self.assertEqual(runtime.main(), 1)
                execute.assert_not_called()

    def test_wrapper_forwards_arguments_environment_and_exit_code(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docker = root / "docker"
            docker.write_text('#!/bin/sh\ncase "$1" in\ncontext) echo unix:///tmp/runtime.sock;;\ninfo) echo 28;;\nesac\n')
            docker.chmod(0o755)
            child = root / "child.py"
            child.write_text('import os, sys\nprint(os.environ["DOCKER_HOST"])\nprint(repr(sys.argv[1:]))\nsys.exit(7)\n')
            environment = os.environ.copy()
            environment.pop("DOCKER_HOST", None)
            environment["DOCKER_CONTEXT"] = "local"
            environment["PATH"] = directory + os.pathsep + environment["PATH"]
            result = subprocess.run(
                ["python3", str(HELPER), "python3", str(child), "two words", ""],
                env=environment, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertIn("unix:///tmp/runtime.sock", result.stdout)
            self.assertIn("['two words', '']", result.stdout)


if __name__ == "__main__":
    unittest.main()
