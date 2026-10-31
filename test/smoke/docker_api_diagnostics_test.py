import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("docker_diagnostics", ROOT / "libexec/makevn/docker/diagnostics.py")
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class DockerApiDiagnosticsTests(unittest.TestCase):
    def test_api_incompatibility_is_found_before_long_failure_summaries(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_text(
                'EnvironmentAndSystemPropertyClientProviderStrategy: Status 400: {"message":'
                '"client version 1.32 is too old. Minimum supported API version is 1.40, '
                'please upgrade your client to a newer version"}\n' + '[ERROR] context failed\n' * 100
            )
            result = diagnostics.diagnose(log)
            self.assertIn("project client uses API 1.32", result)
            self.assertIn("reachable engine requires at least API 1.40", result)
            self.assertIn("dependencies and API configuration", result)
            self.assertNotIn("engine is unavailable", result)

    def test_unrelated_errors_do_not_claim_api_incompatibility(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            for error in ("Cannot connect to the Docker daemon", "Failed to pull image", "BUILD FAILURE"):
                log.write_text(error)
                self.assertEqual(diagnostics.diagnose(log), "")

    def test_missing_log_does_not_replace_original_failure(self):
        self.assertEqual(diagnostics.diagnose("/nonexistent/makevn-test.log"), "")


if __name__ == "__main__":
    unittest.main()
