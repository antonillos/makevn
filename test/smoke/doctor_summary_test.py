#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest
import sys

sys.dont_write_bytecode = True

MODULE = Path(__file__).resolve().parents[2] / "libexec/makevn/common/doctor_summary.py"
spec = importlib.util.spec_from_file_location("doctor_summary", MODULE)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class DoctorSummaryTest(unittest.TestCase):
    def render(self, processes, mounts):
        return "\n".join(summary.summarize(processes, mounts))

    def test_clear_with_pending_mounts(self):
        output = self.render({"status": "clear"}, {"status": "checked", "checks": [{"status": "unverified"}] * 3})
        self.assertIn("no competing test JVMs detected", output)
        self.assertIn("3 detected, 3 pending visibility verification", output)
        self.assertNotIn("{", output)

    def test_conflicts_and_unknown_processes_remain_visible(self):
        output = self.render({"status": "possible_conflict", "processes": [{"pid": 42, "checkout": "/repo"}], "unattributed_test_jvms": 2}, {"status": "unavailable"})
        self.assertIn("PID 42 in /repo; possible shared-service conflict", output)
        self.assertIn("2 could not be attributed", output)
        self.assertIn("verification unavailable", output)

    def test_mount_problems_retain_evidence(self):
        for status in ("warning", "error", "empty_source"):
            with self.subTest(status=status):
                output = self.render({"status": "unavailable"}, {"status": "checked", "checks": [{"status": status, "service": "db", "source": "/host/init.sql", "target": "/init.sql", "reason": "check source"}]})
                self.assertIn("inspection unavailable", output)
                self.assertIn(f"Bind mount {status}: db /host/init.sql -> /init.sql: check source", output)

    def test_no_mounts_and_visible_mounts(self):
        self.assertIn("none detected", self.render({"status": "clear"}, {"status": "checked", "checks": []}))
        self.assertIn("1 detected, 0 pending", self.render({"status": "clear"}, {"status": "checked", "checks": [{"status": "visible"}]}))


if __name__ == "__main__":
    unittest.main()
