import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('scoped', ROOT / 'libexec/makevn/common/scoped_coverage.py')
scoped = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scoped)


class ScopedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--allow-empty', '-qm', 'base'], check=True)
        self.state = self.repo / '.makevn/state/focused-coverage'
        self.source = 'client/src/main/java/example/Owner.java'
        path = self.repo / self.source
        path.parent.mkdir(parents=True)
        path.write_text('class Owner {}')
        self.compiled = self.repo / 'client/target/classes/example/Owner.class'
        self.compiled.parent.mkdir(parents=True)
        self.compiled.write_bytes(b'bytecode')
        self.ut = self.repo / 'client/target/jacoco.exec'
        self.it = self.repo / 'boot/target/classes/boot.coverage'
        self.it.parent.mkdir(parents=True)
        self.ut.write_bytes(b'old UT')
        self.it.write_bytes(b'old IT')

    def ready(self):
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [self.source])
        self.ut.write_bytes(b'new UT')
        self.it.write_bytes(b'new IT')
        scoped.finish(self.repo, self.state)
        return scoped.load(self.repo, self.state)

    def test_snapshot_merges_owners_and_excludes_old_append_data(self):
        manifest = self.ready()
        self.assertEqual({Path(p).read_bytes() for p in manifest['data']}, {b'new UT', b'new IT'})
        self.assertEqual(self.ut.with_name('jacoco.exec.before-focused').read_bytes(), b'old UT')
        self.ut.write_bytes(b'other execution')
        scoped.load(self.repo, self.state)  # Independent snapshot.
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [self.source])
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            scoped.load(self.repo, self.state)

    def test_source_and_snapshot_changes_reject_stale_evidence(self):
        manifest = self.ready()
        path = self.repo / self.source
        path.write_text('class Changed {}')
        with self.assertRaisesRegex(ValueError, 'sources/config changed'):
            scoped.load(self.repo, self.state)
        path.write_text('class Owner {}')
        Path(manifest['data'][0]).write_bytes(b'tamper')
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            scoped.load(self.repo, self.state)

    def test_no_data_and_missing_classes_fail_not_fall_back(self):
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [self.source])
        scoped.finish(self.repo, self.state)
        with self.assertRaisesRegex(ValueError, 'No fresh JaCoCo'):
            scoped.load(self.repo, self.state)
        self.compiled.unlink()
        self.ready_without_load()
        with self.assertRaisesRegex(ValueError, 'Missing changed-class'):
            scoped.load(self.repo, self.state)

    def ready_without_load(self):
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [self.source])
        self.ut.write_bytes(b'new')
        scoped.finish(self.repo, self.state)

    def test_linked_target_is_rejected_before_data_is_rotated(self):
        target = self.repo / 'client/target'
        moved = self.repo / 'linked-target'
        target.rename(moved)
        target.symlink_to(moved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'linked coverage target'):
            scoped.prepare(self.repo, self.state, self.repo, ['client'], [self.source])
        self.assertEqual((moved / 'jacoco.exec').read_bytes(), b'old UT')

    def test_changed_comparison_ref_is_rejected(self):
        subprocess.run(['git', '-C', str(self.repo), 'branch', 'comparison'], check=True)
        scoped.prepare(self.repo, self.state, self.repo, ['client', 'boot'], [self.source], 'comparison...HEAD')
        self.ut.write_bytes(b'new')
        scoped.finish(self.repo, self.state)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--allow-empty', '-qm', 'next'], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'branch', '-f', 'comparison', 'HEAD'], check=True)
        with self.assertRaisesRegex(ValueError, 'Comparison base changed'):
            scoped.load(self.repo, self.state)

    def test_report_is_direct_cli_and_reused_by_second_gate(self):
        manifest = self.ready()
        output = Path(manifest['report'])
        original_run = subprocess.run
        def run(command, **kwargs):
            if command[0] == 'git':
                return original_run(command, **kwargs)
            if command[0] == 'mvn':
                self.assertIn('org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy', command)
                self.assertFalse(Path(command[2]).is_relative_to(self.repo))
                self.assertNotIn('-am', command)
                self.assertNotIn('verify', command)
                (self.state / ('org.jacoco.cli-' + scoped.VERSION + '-nodeps.jar')).touch()
                return subprocess.CompletedProcess(command, 0)
            self.assertEqual(command[3], 'report')
            self.assertNotIn('verify', command)
            (output / 'jacoco.xml').write_text('<report><package name="example"><class name="example/Owner"/></package></report>')
            (output / 'jacoco.csv').write_text('GROUP,PACKAGE,CLASS\nfocused,example,Owner\n')
            (output / 'index.html').write_text('html')
            return subprocess.CompletedProcess(command, 0, '', '')
        with patch.object(scoped.subprocess, 'run', side_effect=run) as mocked:
            scoped.report(self.repo, self.state, 'mvn', 'java')
            scoped.report(self.repo, self.state, 'mvn', 'java')
            calls = [call for call in mocked.call_args_list if call.args[0][0] == 'java']
            self.assertEqual(len(calls), 1)
            self.assertEqual(len([call for call in mocked.call_args_list if call.args[0][0] == 'mvn']), 1)


if __name__ == '__main__':
    unittest.main()
