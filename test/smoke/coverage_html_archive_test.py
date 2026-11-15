"""Focused HTML archives are usable temporarily without polluting a checkout."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'libexec/makevn/coverage/changes.sh'


class CoverageHtmlArchiveTests(unittest.TestCase):
    def test_actual_coverage_script_accepts_archive_without_leaving_markup(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repo = base / 'repo'
            repo.mkdir()
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Test', '-c',
                            'user.email=test@example.com', 'commit', '--allow-empty', '-qm', 'base'], check=True)
            report = base / 'report'
            report.mkdir()
            (report / 'jacoco.csv').write_text('GROUP,PACKAGE,CLASS\n')
            with zipfile.ZipFile(report / 'jacoco-html.zip', 'w') as bundle:
                bundle.writestr('index.html', '<html/>')
            temporary = base / 'temp'
            temporary.mkdir()
            result = subprocess.run(['bash', str(SCRIPT), str(report), 'HEAD'], cwd=repo,
                                    env={**os.environ, 'TMPDIR': str(temporary), 'BASE_PATH': '.', 'MAKEVN_COVERAGE_SCOPED': 'true'},
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(temporary.iterdir()), [])
            self.assertFalse((report / 'index.html').exists())

    def test_archive_is_extracted_for_analysis_then_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            report = base / 'report'
            report.mkdir()
            (report / 'jacoco.csv').write_text('GROUP,PACKAGE,CLASS\n')
            with zipfile.ZipFile(report / 'jacoco-html.zip', 'w') as bundle:
                bundle.writestr('index.html', '<html/>')
                bundle.writestr('example/Owner.java.html', 'covered')
            script = base / 'functions.sh'
            script.write_text(SCRIPT.read_text().split('# Detect changed production Java files')[0])
            temporary = base / 'temp'
            temporary.mkdir()
            command = 'source "$1" "$2" HEAD; [[ -f "$JACOCO_BASE/example/Owner.java.html" && -f "$JACOCO_BASE/jacoco.csv" ]]; printf "%s" "$JACOCO_BASE"'
            result = subprocess.run(['bash', '-c', command, 'test', str(script), str(report)],
                                    env={**os.environ, 'TMPDIR': str(temporary), 'MAKEVN_COVERAGE_SCOPED': 'true'}, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(Path(result.stdout).exists())
            self.assertEqual(list(temporary.iterdir()), [])
            self.assertFalse((report / 'index.html').exists())
            self.assertTrue((report / 'jacoco-html.zip').is_file())

    def test_invalid_archive_fails_and_cleans_temporary_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            report = base / 'report'
            report.mkdir()
            (report / 'jacoco-html.zip').write_text('invalid')
            script = base / 'functions.sh'
            script.write_text(SCRIPT.read_text().split('# Detect changed production Java files')[0])
            temporary = base / 'temp'
            temporary.mkdir()
            result = subprocess.run(['bash', '-c', 'source "$1" "$2" HEAD', 'test', str(script), str(report)],
                                    env={**os.environ, 'TMPDIR': str(temporary), 'MAKEVN_COVERAGE_SCOPED': 'true'}, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(temporary.iterdir()), [])

    def test_global_report_does_not_use_unrelated_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            report = base / 'report'
            report.mkdir()
            (report / 'index.html').write_text('<html/>')
            (report / 'jacoco-html.zip').write_text('unrelated file')
            script = base / 'functions.sh'
            script.write_text(SCRIPT.read_text().split('# Detect changed production Java files')[0])
            result = subprocess.run(['bash', '-c', 'source "$1" "$2" HEAD', 'test', str(script), str(report)],
                                    env={**os.environ, 'MAKEVN_COVERAGE_SCOPED': 'false'}, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
