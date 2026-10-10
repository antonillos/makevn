"""Competing JVM classification never attributes unrelated projects or kills them."""
import importlib.util
from pathlib import Path
import unittest
import io
from contextlib import redirect_stderr
from types import SimpleNamespace
from unittest.mock import patch, Mock
root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("test_processes", root / "libexec/makevn/common/test_processes.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class ProcessTests(unittest.TestCase):
    def test_same_repository_other_worktree_and_foreign_java(self):
        output = "101 1 Sat Oct 10 12:00:00 2026 /jdk/bin/java java -jar /checkout/target/surefire/surefirebooter.jar\n102 1 Sat Oct 10 12:00:01 2026 java java -jar surefirebooter.jar\n103 1 Sat Oct 10 12:00:02 2026 java java -jar app.jar\n"
        identities = {"/repo": ("/repo", "/git/shared"), "/other-worktree/code": ("/other-worktree", "/git/shared"), "/foreign": ("/foreign", "/git/foreign")}
        with patch.object(m, "repository", side_effect=lambda p: identities.get(p)), patch.object(m, "query", return_value=output), patch.object(m, "process_cwd", side_effect=lambda pid: {101: "/other-worktree/code", 102: "/foreign"}.get(pid)):
            result = m.scan("/repo")
        self.assertEqual(result["status"], "possible_conflict")
        self.assertEqual([p["pid"] for p in result["processes"]], [101])
        self.assertEqual(result["processes"][0]["checkout"], "/other-worktree")
    def test_owned_residual_jvm_is_warned_without_termination(self):
        during = "999 1 Sat Oct 10 12:00:00 2026 mvn mvn verify\n1000 999 Sat Oct 10 12:00:01 2026 java java -jar surefirebooter.jar\n"
        after = "1000 1 Sat Oct 10 12:00:01 2026 java java -jar surefirebooter.jar\n1001 1 Sat Oct 10 12:00:02 2026 java java -jar surefirebooter.jar\n"
        child = SimpleNamespace(pid=999, poll=Mock(side_effect=[None, 0]), returncode=0, send_signal=Mock())
        captured = io.StringIO()
        with patch.object(m.subprocess, "Popen", return_value=child), patch.object(m, "query", side_effect=[during, after]), patch.object(m.time, "sleep"), redirect_stderr(captured):
            self.assertEqual(m.watch_command(["mvn", "verify"]), 0)
        self.assertIn("PID 1000", captured.getvalue())
        self.assertNotIn("PID 1001", captured.getvalue())
        child.send_signal.assert_not_called()

    def test_unavailable_is_not_certified_clear(self):
        with patch.object(m, "repository", return_value=None), patch.object(m, "query", return_value=None):
            self.assertEqual(m.scan("/repo")["status"], "unavailable")
    def test_unattributed_jvm_is_not_false_conflict(self):
        output = "101 1 Sat Oct 10 12:00:00 2026 java java org.apache.maven.surefire.booter.ForkedBooter\n"
        with patch.object(m, "repository", side_effect=lambda p: ("/repo", "/git") if p == "/repo" else None), patch.object(m, "query", return_value=output), patch.object(m, "process_cwd", return_value=None):
            result = m.scan("/repo")
        self.assertEqual(result["unattributed_test_jvms"], 1)
        self.assertEqual(result["processes"], [])

if __name__ == "__main__": unittest.main()
