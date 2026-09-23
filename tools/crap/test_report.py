#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REPORTER = ROOT / "tools/crap/report.py"
JAVA_REPORTER = ROOT / "libexec/makevn/crap/report.py"
SHELL_REPORTER = ROOT / "tools/crap/shell_report.py"


class CrapReportTests(unittest.TestCase):
    def run_report(
        self,
        rust_crap=9,
        shell_crap=7,
        limits=(1, 0),
        base_limits=None,
        threshold=8,
        base_threshold=None,
        effective_threshold=8,
    ):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            for language, crap in (("rust", rust_crap), ("shell", shell_crap)):
                (tmp / f"{language}.json").write_text(json.dumps({"entries": [{"file": f"src.{language}", "line": 1, "function": "main", "cyclomatic": 2, "coverage": 50, "crap": crap}]}))
            baseline = {"threshold": threshold, "max_warnings": {"rust": limits[0], "shell": limits[1], "total": sum(limits)}}
            (tmp / "baseline.json").write_text(json.dumps(baseline))
            args = ["python3", str(REPORTER), "--rust", str(tmp / "rust.json"), "--shell", str(tmp / "shell.json"), "--baseline", str(tmp / "baseline.json"), "--output-dir", str(tmp / "out"), "--threshold", str(effective_threshold)]
            if base_limits:
                (tmp / "base.json").write_text(json.dumps({"threshold": threshold if base_threshold is None else base_threshold, "max_warnings": {"rust": base_limits[0], "shell": base_limits[1], "total": sum(base_limits)}}))
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

    def test_threshold_may_decrease_but_never_increase_or_diverge(self):
        result, _ = self.run_report(base_limits=(1, 0), threshold=7, base_threshold=8, effective_threshold=7)
        self.assertEqual(result.returncode, 0)
        result, report = self.run_report(base_limits=(1, 0), threshold=9, base_threshold=8, effective_threshold=9)
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(report)
        result, report = self.run_report(effective_threshold=9)
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

    def test_java_report_explains_missing_coverage_against_jacoco_xml(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            source = tmp / "java.json"
            source.write_text(json.dumps({"entries": [
                {"class": "demo.Present", "method": "unmatched", "file": "Present.java", "line": 3, "crap": None},
                {"class": "demo.Absent", "method": "missing", "file": "Absent.java", "line": 7, "crap": None},
            ]}))
            xml = tmp / "jacoco.xml"
            xml.write_text('<report><package name="demo"><class name="demo/Present"/></package></report>')
            out = tmp / "out"
            result = subprocess.run(
                ["python3", str(JAVA_REPORTER), "--input", str(source), "--jacoco-xml", str(xml), "--output-dir", str(out)],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("1 method(s) in classes absent from JaCoCo XML; 1 method(s) not matched", result.stderr)
            gaps = (out / "coverage-gaps.txt").read_text()
            self.assertIn("demo.Absent#missing", gaps)
            self.assertIn("demo.Present#unmatched", gaps)
            self.assertIn("Check aggregate report module dependencies", gaps)

    def test_java_report_rejects_overlapping_jacoco_methods(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            method = {"file": "Example.java", "line": 8, "class": "Example", "method": "risk", "complexity": 3, "coverage_percent": 50, "crap": 4.125}
            for name in ("unit", "integration"):
                (tmp / f"{name}.json").write_text(json.dumps({"entries": [method]}))
            result = subprocess.run(
                ["python3", str(JAVA_REPORTER), "--input", str(tmp / "unit.json"), "--input", str(tmp / "integration.json"), "--output-dir", str(tmp / "out"), "--max-warnings", "0"],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("overlapping JaCoCo reports", result.stderr)
            self.assertFalse((tmp / "out/report.json").exists())

    def test_shell_report_uses_lexical_function_ranges(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            source = tmp / "fixture.sh"
            source.write_text("last() {\n  printf 'untested\\n'\n}\nprintf 'covered main\\n'\n")
            complexity = tmp / "shell.csv"
            complexity.write_text(
                "file,func,lineno,lloc,ccn,lines,comment,blank\n"
                '"fixture.sh","last",1,1,2,0,0,0\n'
                '"fixture.sh","<main>",0,1,2,0,0,0\n'
            )
            coverage = tmp / "coverage.json"
            coverage.write_text(
                json.dumps(
                    {
                        "smoke": {
                            "coverage": {
                                str(source): {"lines": [None, 0, None, 1]}
                            }
                        }
                    }
                )
            )
            output = tmp / "report.json"
            result = subprocess.run(
                [
                    "python3",
                    str(SHELL_REPORTER),
                    "--root",
                    str(tmp),
                    "--complexity",
                    str(complexity),
                    "--coverage",
                    str(coverage),
                    "--output",
                    str(output),
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            entries = {entry["function"]: entry for entry in json.loads(output.read_text())["entries"]}
            self.assertEqual(entries["last"]["end_line"], 3)
            self.assertEqual(entries["last"]["coverage"], 0.0)
            self.assertEqual(entries["<main>"]["coverage"], 100.0)

    def test_shell_report_accepts_inline_closing_braces(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            source = tmp / "fixture.sh"
            source.write_text("inline() { printf x; }\ntrailing() {\n  printf y; }\n")
            complexity = tmp / "shell.csv"
            complexity.write_text(
                "file,func,lineno,lloc,ccn,lines,comment,blank\n"
                '"fixture.sh","inline",1,1,2,0,0,0\n'
                '"fixture.sh","trailing",2,1,2,0,0,0\n'
            )
            coverage = tmp / "coverage.json"
            coverage.write_text(json.dumps({"smoke": {"coverage": {str(source): {"lines": [1, 1, 1]}}}}))
            output = tmp / "report.json"
            result = subprocess.run(
                ["python3", str(SHELL_REPORTER), "--root", str(tmp), "--complexity", str(complexity), "--coverage", str(coverage), "--output", str(output)],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            entries = {entry["function"]: entry for entry in json.loads(output.read_text())["entries"]}
            self.assertEqual(entries["inline"]["end_line"], 1)
            self.assertEqual(entries["trailing"]["end_line"], 3)

    def test_shell_report_treats_function_only_main_as_covered(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            source = tmp / "fixture.sh"
            source.write_text("only() { printf x; }\n")
            complexity = tmp / "shell.csv"
            complexity.write_text(
                "file,func,lineno,lloc,ccn,lines,comment,blank\n"
                '"fixture.sh","only",1,1,1,0,0,0\n'
                '"fixture.sh","<main>",0,0,1,0,0,0\n'
            )
            coverage = tmp / "coverage.json"
            coverage.write_text(json.dumps({"smoke": {"coverage": {str(source): {"lines": [1]}}}}))
            output = tmp / "report.json"
            result = subprocess.run(
                ["python3", str(SHELL_REPORTER), "--root", str(tmp), "--complexity", str(complexity), "--coverage", str(coverage), "--output", str(output)],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            entries = {entry["function"]: entry for entry in json.loads(output.read_text())["entries"]}
            self.assertEqual(entries["<main>"]["coverage"], 100.0)
            self.assertEqual(entries["<main>"]["crap"], 1.0)


if __name__ == "__main__":
    unittest.main()
