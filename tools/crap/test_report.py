#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REPORTER = ROOT / "tools/crap/report.py"
JAVA_REPORTER = ROOT / "libexec/makevn/crap/report.py"


class CrapReportTests(unittest.TestCase):
    def run_report(self, rust_crap=9, shell_crap=7, limits=(1, 0), base_limits=None):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            for language, crap in (("rust", rust_crap), ("shell", shell_crap)):
                (tmp / f"{language}.json").write_text(json.dumps({"entries": [{"file": f"src.{language}", "line": 1, "function": "main", "cyclomatic": 2, "coverage": 50, "crap": crap}]}))
            baseline = {"max_warnings": {"rust": limits[0], "shell": limits[1], "total": sum(limits)}}
            (tmp / "baseline.json").write_text(json.dumps(baseline))
            args = ["python3", str(REPORTER), "--rust", str(tmp / "rust.json"), "--shell", str(tmp / "shell.json"), "--baseline", str(tmp / "baseline.json"), "--output-dir", str(tmp / "out")]
            if base_limits:
                (tmp / "base.json").write_text(json.dumps({"max_warnings": {"rust": base_limits[0], "shell": base_limits[1], "total": sum(base_limits)}}))
                args += ["--base-baseline", str(tmp / "base.json")]
            result = subprocess.run(args, text=True, capture_output=True, check=False)
            report = json.loads((tmp / "out/report.json").read_text()) if (tmp / "out/report.json").exists() else None
            return result, report

    def test_gate_passes_at_language_baselines(self):
        result, report = self.run_report()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(report["gate"]["warnings"], {"rust": 1, "shell": 0, "total": 1})

    def test_gate_fails_language_regression(self):
        result, report = self.run_report(shell_crap=9)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["gate"]["status"], "failed")

    def test_baseline_may_decrease_but_never_increase(self):
        result, _ = self.run_report(limits=(0, 0), base_limits=(1, 0))
        self.assertEqual(result.returncode, 1)  # valid reduction, current warning now breaks it
        result, report = self.run_report(limits=(2, 0), base_limits=(1, 0))
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(report)

    def test_missing_coverage_is_infrastructure_error(self):
        result, _ = self.run_report(rust_crap=None)
        self.assertEqual(result.returncode, 2)

    def test_java_report_rejects_partially_missing_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            payload = {
                "entries": [
                    {"file": "Measured.java", "method": "measured", "crap": 2.0},
                    {"file": "Missing.java", "method": "missing", "crap": None},
                ]
            }
            source = tmp / "java.json"
            source.write_text(json.dumps(payload))
            result = subprocess.run(
                [
                    "python3",
                    str(JAVA_REPORTER),
                    "--input",
                    str(source),
                    "--output-dir",
                    str(tmp / "out"),
                    "--max-warnings",
                    "0",
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("1 Java method(s) without coverage", result.stderr)


if __name__ == "__main__":
    unittest.main()
