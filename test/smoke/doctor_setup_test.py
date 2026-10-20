"""Validate structured answers and transactional config persistence."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("doctor_setup", ROOT / "libexec/makevn/common/doctor_setup.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class DoctorSetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.path = self.repo / ".makevn/config"
        self.path.parent.mkdir()
        self.path.write_text('# Keep this comment\nOTHER="keep"\nMAKEVN_COMPOSE_FILE=""\n')
        self.details = setup.collect_questions([
            str(self.repo), "/boot/a\n/boot/b", "/e2e/a\n/e2e/b",
            "http://localhost:8080/health", "local; ci", "true", "true", "true"])
        self.snapshot = {"repository_analysis": {"repository_support_status": "supported"},
                         "suggested_next_step": {"next": ""}, "interactive_setup": self.details}

    def apply(self, answers, token=None):
        setup.apply_answers(str(self.repo), {"setupToken": token or self.details["setupToken"],
                                            "answers": answers}, self.snapshot)

    def test_all_answers_and_shell_roundtrip(self):
        url = "http://localhost/health?value='$(touch${IFS}SENTINEL)`id`&other=ok"
        self.apply({"boot_compose": "/boot/b", "e2e_compose": "/e2e/a", "local_containers": False,
                    "app_health_url": url, "karate_app_profiles": "standalone,local-2"})
        result = subprocess.run(["bash", "-c", 'source "$1"; printf "%s\\n" "$MAKEVN_APP_HEALTH_URL" "$MAKEVN_COMPOSE_FILE" "$MAKEVN_E2E_COMPOSE_FILE" "$MAKEVN_LOCAL_CONTAINERS" "$OTHER"',
                                 "bash", str(self.path)], cwd=self.repo, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.splitlines(), [url, "/boot/b", "/e2e/a", "", "keep"])
        self.assertFalse((self.repo / "SENTINEL").exists())
        self.assertIn("# Keep this comment", self.path.read_text())
        self.assertEqual(self.path.read_text().count("MAKEVN_COMPOSE_FILE="), 1)

    def test_partial_answer_only_changes_answered_setting(self):
        self.apply({"local_containers": True})
        self.assertIn("MAKEVN_LOCAL_CONTAINERS=TRUE", self.path.read_text())
        self.assertNotIn("MAKEVN_APP_HEALTH_URL", self.path.read_text())

    def test_invalid_batches_are_atomic(self):
        before = self.path.read_bytes()
        for answers in [{}, [], {"unknown": "x"}, {"boot_compose": "/deleted"},
                        {"local_containers": "false"}, {"local_containers": 1},
                        {"app_health_url": "file:///tmp/health"}, {"app_health_url": "http://host/a b"},
                        {"karate_app_profiles": "${DYNAMIC}"}, {"app_health_url": "http://a/\nb"},
                        {"local_containers": True, "karate_app_profiles": ""}]:
            with self.subTest(answers=answers), self.assertRaises(ValueError):
                self.apply(answers)
            self.assertEqual(before, self.path.read_bytes())

    def test_changed_config_or_questions_rejects_old_answers(self):
        self.path.write_text(self.path.read_text() + "# external edit\n")
        before = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, "changed"):
            self.apply({"local_containers": True})
        self.assertEqual(before, self.path.read_bytes())
        self.snapshot["interactive_setup"]["questions"][0]["options"].append("/boot/new")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.apply({"boot_compose": "/boot/b"})
        self.assertEqual(before, self.path.read_bytes())

    def test_initialization_and_support_are_required(self):
        for support, next_command in [("unsupported", ""), ("supported", "makevn init"),
                                      ("supported", "makevn init --force")]:
            self.snapshot["repository_analysis"]["repository_support_status"] = support
            self.snapshot["suggested_next_step"]["next"] = next_command
            before = self.path.read_bytes()
            with self.assertRaises(ValueError):
                self.apply({"local_containers": True})
            self.assertEqual(before, self.path.read_bytes())

    def test_config_writer_rejects_concurrent_edits(self):
        before = self.path.read_bytes()
        self.path.write_text("# someone else's config\n")
        with self.assertRaisesRegex(ValueError, "changed"):
            setup.write_config(self.path, {"MAKEVN_LOCAL_CONTAINERS": "TRUE"}, before)
        self.assertEqual(self.path.read_text(), "# someone else's config\n")
        self.assertFalse(list(self.path.parent.glob(".config-*")))


if __name__ == "__main__":
    unittest.main()
