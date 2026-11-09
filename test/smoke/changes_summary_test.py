import importlib.util
from pathlib import Path
import os
import json
from types import SimpleNamespace
from unittest.mock import patch
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
            self.assertIn('not established', result['globalGates'])


    def test_stages_record_failures_retries_and_reset_on_new_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            state = repo / '.makevn/focused-coverage/run.json'
            state.parent.mkdir(parents=True)
            state.write_text(json.dumps({'classes': 'run-one'}))
            stamp = repo / 'started'
            stamp.touch()
            summary.main([str(repo), str(repo), str(stamp), '0'])
            output = summary.summary_path(repo)
            self.assertEqual(json.loads(output.read_text())['crap']['status'], 'not_run')
            summary.update_stage(repo, 'coverage-changes', 2)
            result = json.loads(output.read_text())
            self.assertEqual(result['coverage'], {'status': 'failed', 'exitCode': 2})
            self.assertEqual(result['crap']['status'], 'not_run')
            report = repo / 'coverage'
            report.mkdir()
            (report / 'jacoco.xml').write_text('<report><counter type="INSTRUCTION" missed="1" covered="9"/></report>')
            fake = SimpleNamespace(load=lambda *args: {'expected': ['demo/Owner'], 'report': str(report)})
            with patch.dict('sys.modules', scoped_coverage=fake):
                summary.update_stage(repo, 'coverage-changes', 0)
                crap = repo / '.makevn/reports/crap-changes/report.json'
                crap.parent.mkdir(parents=True)
                crap.write_text(json.dumps({'diagnostics': {'java_methods': 1},
                                            'gate': {'warnings': 1, 'status': 'reported'}}))
                summary.update_stage(repo, 'crap-changes', 0)
            result = json.loads(output.read_text())
            self.assertEqual(result['coverage']['counters']['INSTRUCTION'], {'missed': 1, 'covered': 9})
            self.assertEqual(result['crap']['status'], 'passed')
            self.assertEqual(result['crap']['gate'], 'reported')
            self.assertEqual(result['crap']['warnings'], 1)
            summary.update_stage(repo, 'coverage-changes', 1)
            result = json.loads(output.read_text())
            self.assertEqual(result['crap']['status'], 'not_run')
            self.assertEqual(result['crap']['reason'], 'coverage did not pass')
            state.write_text(json.dumps({'classes': 'run-two'}))
            summary.update_stage(repo, 'crap-changes', 1)
            self.assertEqual(json.loads(output.read_text()), result)
            summary.main([str(repo), str(repo), str(stamp), '1'])
            result = json.loads(output.read_text())
            self.assertEqual(result['verification']['status'], 'failed')
            self.assertEqual(result['coverage']['status'], 'not_run')
            self.assertEqual(result['crap']['status'], 'not_run')

    def test_no_changed_classes_are_not_applicable(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            state = repo / '.makevn/focused-coverage/run.json'
            state.parent.mkdir(parents=True)
            state.write_text('{}')
            stamp = repo / 'started'
            stamp.touch()
            summary.main([str(repo), str(repo), str(stamp), '0'])
            with patch.dict('sys.modules', scoped_coverage=SimpleNamespace(load=lambda *args: {'expected': []})):
                summary.update_stage(repo, 'coverage-changes', 0)
                summary.update_stage(repo, 'crap-changes', 0)
            result = json.loads(summary.summary_path(repo).read_text())
            self.assertEqual(result['coverage']['status'], 'not_applicable')
            self.assertEqual(result['crap']['status'], 'not_applicable')


if __name__ == '__main__':
    unittest.main()
