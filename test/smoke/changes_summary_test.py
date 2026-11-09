import importlib.util
from pathlib import Path
import os
import tempfile
import unittest

path = Path(__file__).resolve().parents[2] / 'libexec/makevn/common/changes_summary.py'
spec = importlib.util.spec_from_file_location('changes_summary', path)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class SummaryTests(unittest.TestCase):
    def test_stale_reports_are_excluded_and_failure_is_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for owner, stamp in [('old', 1), ('current', 20)]:
                report = base / owner / 'target/surefire-reports/TEST-Suite.xml'
                report.parent.mkdir(parents=True)
                report.write_text('<testsuite tests="3" failures="1" errors="0" skipped="1"/>')
                os.utime(report, (stamp, stamp))
            result = summary.summarize(base, 10, 1)
            self.assertEqual(result['exitCode'], 1)
            self.assertEqual(result['modules'], {'current': dict(tests=3, failures=1, errors=0, skipped=1)})
            self.assertIn('not evaluated', result['crap'])


if __name__ == '__main__':
    unittest.main()
