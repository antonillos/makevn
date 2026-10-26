"""Validate structured answers and transactional config persistence."""
import importlib.util
import multiprocessing
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("doctor_setup", ROOT / "libexec/makevn/common/doctor_setup.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


def configure_in_process(repo, snapshot, answers, started, replacing, release, results):
    replace = setup.os.replace

    def pause_before_replace(source, destination):
        replacing.set()
        if release is not None and not release.wait(10):
            raise TimeoutError("Timed out releasing the configuration writer")
        replace(source, destination)

    setup.os.replace = pause_before_replace
    started.set()
    try:
        if snapshot is None:
            setup.write_config(Path(repo) / ".makevn/config", answers)
        else:
            setup.apply_answers(repo, {"setupToken": snapshot["interactive_setup"]["setupToken"],
                                       "answers": answers}, snapshot)
        results.put((multiprocessing.current_process().name, None))
    except ValueError as error:
        results.put((multiprocessing.current_process().name, str(error)))


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

    def test_jdk_choice_requires_an_offered_path_and_preserves_other_settings(self):
        self.details = setup.collect_questions([
            str(self.repo), "", "", "", "", "false", "false", "false",
            "/jdks/25.0.2\n/jdks/25.0.3", "/jdks/25.0.2"])
        self.snapshot["interactive_setup"] = self.details
        item = self.details["questions"][0]
        self.assertEqual(item["id"], "code_java_home")
        self.assertEqual(item["suggestedValue"], "/jdks/25.0.2")
        before = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, "available option"):
            self.apply({"code_java_home": "/jdks/27"})
        self.assertEqual(self.path.read_bytes(), before)
        self.apply({"code_java_home": "/jdks/25.0.3"})
        self.assertIn("MAKEVN_CODE_JAVA_HOME=/jdks/25.0.3", self.path.read_text())
        self.assertIn('OTHER="keep"', self.path.read_text())

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
        setup.write_config(self.path, {"MAKEVN_LOCAL_CONTAINERS": "TRUE"})
        self.assertIn("MAKEVN_LOCAL_CONTAINERS=TRUE", self.path.read_text())

    def concurrent_writers(self, use_token):
        context = multiprocessing.get_context("spawn")
        started_first, started_second = context.Event(), context.Event()
        replacing_first, replacing_second = context.Event(), context.Event()
        release_first, results = context.Event(), context.Queue()
        snapshot = self.snapshot if use_token else None
        first_answers = {"local_containers": True} if use_token else {"MAKEVN_LOCAL_CONTAINERS": "TRUE"}
        second_answers = {"app_health_url": "http://localhost/health"} if use_token else {"MAKEVN_APP_HEALTH_URL": "http://localhost/health"}
        first = context.Process(name="first", target=configure_in_process,
                                args=(str(self.repo), snapshot, first_answers, started_first,
                                      replacing_first, release_first, results))
        second = context.Process(name="second", target=configure_in_process,
                                 args=(str(self.repo), snapshot, second_answers, started_second,
                                       replacing_second, None, results))
        processes = []
        try:
            first.start()
            processes.append(first)
            self.assertTrue(replacing_first.wait(10), "First writer did not reach replacement")
            second.start()
            processes.append(second)
            self.assertTrue(started_second.wait(10), "Second writer did not start")
            self.assertFalse(replacing_second.wait(0.5), "Second writer bypassed the active transaction")
        finally:
            release_first.set()
            for process in processes:
                process.join(10)
                if process.is_alive():
                    process.terminate()
                    process.join(5)
        self.assertEqual([first.exitcode, second.exitcode], [0, 0])
        outcomes = dict(results.get(timeout=5) for _ in processes)
        results.close()
        results.join_thread()
        self.assertIsNone(outcomes["first"])
        self.assertIn("MAKEVN_LOCAL_CONTAINERS=TRUE", self.path.read_text())
        self.assertFalse(list(self.path.parent.glob(".config-*")))
        return outcomes

    def test_concurrent_answers_with_same_token_reject_the_second_writer(self):
        outcomes = self.concurrent_writers(use_token=True)
        self.assertIn("changed", outcomes["second"])
        self.assertNotIn("MAKEVN_APP_HEALTH_URL", self.path.read_text())

    def test_concurrent_cli_updates_preserve_both_answers(self):
        outcomes = self.concurrent_writers(use_token=False)
        self.assertIsNone(outcomes["second"])
        self.assertIn("MAKEVN_APP_HEALTH_URL=http://localhost/health", self.path.read_text())


if __name__ == "__main__":
    unittest.main()
