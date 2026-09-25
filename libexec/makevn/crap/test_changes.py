import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).parent


class CrapChangesTest(unittest.TestCase):
    def test_change_inventory_includes_committed_staged_unstaged_and_new(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True).stdout.decode().strip()
            git("init", "-q")
            path = root / "module/src/main/java/demo/Example.java"
            path.parent.mkdir(parents=True)
            path.write_text("a\nb\nc\nd\n")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            path.write_text("a\ncommitted\nc\nd\n")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "change")
            path.write_text("a\ncommitted\nstaged\nd\n")
            git("add", ".")
            path.write_text("a\ncommitted\nstaged\nunstaged\n")
            new = root / "module/src/main/java/demo/New.java"
            new.write_text("class New {}\n")
            output = root / "changes.json"
            result = subprocess.run([sys.executable, str(HERE / "changes.py"), "--repo-root", str(root), "--base", base, "--output", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            files = json.loads(output.read_text())["files"]
            self.assertEqual(files["module/src/main/java/demo/New.java"], [[1, 1]])
            ranges = files["module/src/main/java/demo/Example.java"]
            self.assertTrue(any(a <= 2 <= b for a, b in ranges))
            self.assertTrue(any(a <= 3 <= b for a, b in ranges))
            self.assertTrue(any(a <= 4 <= b for a, b in ranges))

    def test_only_changed_missing_coverage_blocks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "module/src/main/java/demo/Example.java"
            source.parent.mkdir(parents=True)
            source.write_text("class Example {}\n")
            raw = root / "raw.json"
            raw.write_text(json.dumps({"entries": [
                {"file": "src/main/java/demo/Example.java", "line": 3, "end_line": 6, "class": "demo.Example", "method": "changed", "crap": 9, "complexity": 4, "coverage_percent": 50},
                {"file": "src/main/java/demo/Example.java", "line": 12, "end_line": 15, "class": "demo.Example", "method": "old", "crap": None},
            ]}))
            xml = root / "jacoco.xml"
            xml.write_text('<report><package><class name="demo/Example"/></package></report>')
            changes = root / "changes.json"
            changes.write_text(json.dumps({"base": "main", "merge_base": "abc", "files": {"module/src/main/java/demo/Example.java": [[4, 4]]}}))
            command = [sys.executable, str(HERE / "report.py"), "--input", str(raw), "--jacoco-xml", str(xml), "--output-dir", str(root / "output"), "--changes-file", str(changes), "--repo-root", str(root), "--source-root", str(root / "module")]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((root / "output/report.json").read_text())
            self.assertEqual([entry["symbol"] for entry in report["entries"]], ["demo.Example#changed"])
            changes.write_text(json.dumps({"base": "main", "merge_base": "abc", "files": {"module/src/main/java/demo/Example.java": [[13, 13]]}}))
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("module/src/main/java/demo/Example.java:12", result.stderr)
            self.assertIn("method not matched", result.stderr)


if __name__ == "__main__":
    unittest.main()
