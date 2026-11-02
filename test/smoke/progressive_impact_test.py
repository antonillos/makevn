"""Exercise static-first selection and additive evidence without Maven."""
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec/makevn/common'))
import progressive_impact as progressive
import observe_test_impact as observer
import test_impact as impact


class ProgressiveImpactTests(unittest.TestCase):
    def setUp(self):
        executable = shutil.which('java')
        if executable is None:
            self.skipTest('JDK required')
        self.java = Path(executable)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name).resolve()
        self.source = 'src/main/java/example/Owner.java'
        self.files = {
            self.source: 'package example; class Owner { int value() { return 1; } }',
            'src/main/java/example/Consumer.java': 'package example; class Consumer { Owner owner; }',
            'src/main/java/example/Other.java': 'package example; class Other {}',
            'src/test/java/example/OwnerTest.java': 'package example; class OwnerTest { Owner owner; }',
            'src/test/java/example/ConsumerTest.java': 'package example; class ConsumerTest { Consumer consumer; }',
            'src/test/java/example/OtherTest.java': 'package example; class OtherTest { Other other; }',
        }
        for name, content in self.files.items():
            file = self.repo / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(content)
        (self.repo / 'pom.xml').write_text('<project/>')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.org',
                        'commit', '--no-gpg-sign', '-qm', 'fixture'], check=True)
        self.context = {'java': 'fixture', 'environment': {'JAVA_HOME': 'runner-specific', 'PATH': 'runner-specific'}}
        patcher = patch.object(impact, 'context', side_effect=lambda _: {
            'java': self.context['java'], 'environment': dict(self.context['environment'])})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, MAKEVN_TEST_IMPACT_JAVA=str(self.java)).start()

    def initialize(self, write=True):
        return progressive.initialize(self.repo, self.repo, self.java, write)

    def plan(self):
        with contextlib.redirect_stderr(io.StringIO()):
            return progressive.narrow(self.repo, self.repo, '.', [self.source], set(), 'HEAD')

    def edit(self):
        (self.repo / self.source).write_text(self.files[self.source].replace('return 1', 'return 2'))

    def execution(self, before, names=('OtherTest',), loaded=('Owner',)):
        folder = self.repo / '.makevn/test-impact/evidence'
        folder.mkdir(parents=True, exist_ok=True)
        stamp = folder / 'stamp'
        stamp.touch()
        target = self.repo / 'target/surefire-reports'
        target.mkdir(parents=True, exist_ok=True)
        for name in names:
            (target / ('TEST-' + name + '.xml')).write_text(
                '<testsuite><testcase classname="example.' + name + '"/></testsuite>')
        (folder / '1.log').write_text(''.join(
            '[0.1s][info][class,load] example.' + name + ' source: file:/fixture/classes/\n'
            for name in [*names, *loaded]))
        return folder, stamp

    def test_static_init_and_readonly_preview_need_no_build_or_tests(self):
        preview = self.initialize(False)
        self.assertFalse(progressive.path(self.repo).exists())
        self.assertEqual(len(progressive.tests(preview['facts'])), 3)
        value = self.initialize()
        self.assertEqual(value['observations'], {})
        self.assertFalse((self.repo / 'target').exists())
        self.edit()
        self.assertEqual(self.plan(), {'example.OwnerTest', 'example.ConsumerTest'})

    def test_selection_works_without_explicit_initialization(self):
        self.edit()
        self.assertEqual(self.plan(), {'example.OwnerTest', 'example.ConsumerTest'})
        self.assertFalse(progressive.path(self.repo).exists())
        from changes_scope import focused_plan
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(focused_plan(self.repo, self.repo, 'HEAD', [self.source]),
                             '.\texample.ConsumerTest,example.OwnerTest')

    def test_observation_adds_dependencies_and_never_replaces_static_edges(self):
        before = self.initialize()
        traces, stamp = self.execution(before)
        progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        value = progressive.load(self.repo)
        self.assertEqual(value['observations'], {'example.OtherTest': ['example.Owner']})
        self.edit()
        self.assertEqual(self.plan(), {'example.OwnerTest', 'example.ConsumerTest', 'example.OtherTest'})

    def test_full_suite_attributes_execution_superset_to_each_executed_class(self):
        before = self.initialize()
        traces, stamp = self.execution(before, ('OwnerTest', 'OtherTest'), ('Owner', 'Other'))
        progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        observations = progressive.load(self.repo)['observations']
        self.assertEqual(observations['example.OwnerTest'], ['example.Other', 'example.Owner'])
        self.assertEqual(observations['example.OtherTest'], observations['example.OwnerTest'])
        (self.repo / 'target/surefire-reports/TEST-OwnerTest.xml').unlink()
        before = self.initialize()
        traces, stamp = self.execution(before, ('OtherTest',), ('Consumer',))
        progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        value = progressive.load(self.repo)['observations']
        self.assertIn('example.Consumer', value['example.OtherTest'])
        self.assertIn('example.Owner', value['example.OwnerTest'])

    def test_stale_failed_skipped_and_untraced_tests_supply_no_runtime_edges(self):
        before = self.initialize()
        traces, stamp = self.execution(before)
        report = self.repo / 'target/surefire-reports/TEST-OtherTest.xml'
        report.write_text('<testsuite><testcase classname="example.OtherTest"><failure/></testcase></testsuite>')
        with self.assertRaisesRegex(ValueError, 'failed reports'):
            progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        report.write_text('<testsuite><testcase classname="example.OtherTest"><skipped/></testcase></testsuite>')
        progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        self.assertEqual(progressive.load(self.repo)['observations'], {})
        self.assertIn('example.OtherTest', progressive.load(self.repo)['skipped'])
        report.write_text('<testsuite><testcase classname="example.OtherTest"/></testsuite>')
        os.utime(report, ns=(stamp.stat().st_mtime_ns - 1_000_000_000,) * 2)
        progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        self.assertEqual(progressive.load(self.repo)['observations'], {})
        report.touch()
        (traces / '1.log').write_text('[0.1s][info][class,load] example.Owner source: file:/fixture/classes/\n')
        progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        self.assertEqual(progressive.load(self.repo)['observations'], {})

    def test_jdk_config_and_dependency_changes_invalidate_observations(self):
        before = self.initialize()
        traces, stamp = self.execution(before)
        progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        self.context['java'] = 'another JDK'
        self.assertEqual(self.initialize()['observations'], {})
        self.context['java'] = 'fixture'
        before = self.initialize()
        progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        (self.repo / 'pom.xml').write_text('<project><properties/></project>')
        self.assertEqual(self.initialize()['observations'], {})
        jar = self.repo / 'dependency.jar'
        jar.write_bytes(b'one')
        value = self.initialize()
        value['jars'] = {str(jar): impact.digest(jar)}
        value['observations'] = {'example.OtherTest': ['example.Owner']}
        impact.sealed_save(progressive.path(self.repo), value)
        jar.write_bytes(b'two')
        self.assertEqual(self.initialize()['observations'], {})

    def test_changed_inputs_during_execution_discard_evidence(self):
        before = self.initialize()
        traces, stamp = self.execution(before)
        self.edit()
        with self.assertRaisesRegex(ValueError, 'inputs changed'):
            progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        self.assertEqual(progressive.load(self.repo)['observations'], {})

    def test_structural_and_shared_state_changes_retain_complete_suite(self):
        self.initialize()
        for content in ['package example; class Owner { long value() { return 2; } }',
                        'package example; class Owner { int value() { System.setProperty("x", "y"); return 2; } }']:
            (self.repo / self.source).write_text(content)
            self.assertIsNone(self.plan())

    def test_nested_aliases_and_interface_dispatch_retain_consumers(self):
        parsed = {
            'src/main/java/Implementation.java': {'class': 'Implementation', 'declared': ['Implementation', 'Nested'], 'names': ['Contract']},
            'src/main/java/Contract.java': {'class': 'Contract', 'declared': ['Contract'], 'names': []},
            'src/test/java/ContractTest.java': {'class': 'ContractTest', 'names': ['Contract']},
            'src/test/java/NestedTest.java': {'class': 'NestedTest', 'names': ['Nested']},
            'src/test/java/ContextTest.java': {'class': 'ContextTest', 'names': ['SpringBootTest']},
        }
        self.assertEqual(progressive.consumers(parsed, {'Implementation'}),
                         {'Implementation', 'Contract', 'ContractTest', 'NestedTest', 'ContextTest'})

    def test_normal_success_enriches_without_replaying_the_command(self):
        script = """
import os
from pathlib import Path
root = Path.cwd()
count = root / '.makevn/calls'
count.write_text(str(int(count.read_text()) + 1) if count.exists() else '1')
target = root / 'target/surefire-reports'
target.mkdir(parents=True, exist_ok=True)
(target / 'TEST-OwnerTest.xml').write_text('<testsuite><testcase classname="example.OwnerTest"/></testsuite>')
folder = os.environ['JAVA_TOOL_OPTIONS'].split('file=')[1].split('/%p.log')[0]
(Path(folder) / '123.log').write_text('[0.1s][info][class,load] example.OwnerTest source: file:/fixture/classes/\\n'
                                      '[0.1s][info][class,load] example.Owner source: file:/fixture/classes/\\n')
"""
        command = [sys.executable, '-c', script]
        previous = Path.cwd()
        try:
            os.chdir(self.repo)
            result = observer.run(self.repo, self.repo, self.java, command)
        finally:
            os.chdir(previous)
        self.assertEqual(result, 0)
        self.assertEqual((self.repo / '.makevn/calls').read_text(), '1')
        self.assertEqual(progressive.load(self.repo)['observations'], {'example.OwnerTest': ['example.Owner']})

    def test_isolated_evidence_merges_with_progressive_observations(self):
        before = self.initialize()
        traces, stamp = self.execution(before)
        progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)
        progressive.absorb_isolated(self.repo, self.repo, self.java,
                                    {'records': {'example.OwnerTest': ['example.Owner']},
                                     'jars': {}, 'skipped': {}})
        self.assertEqual(progressive.load(self.repo)['observations'],
                         {'example.OwnerTest': ['example.Owner'], 'example.OtherTest': ['example.Owner']})

    def test_concurrent_successes_preserve_both_observations(self):
        from concurrent.futures import ThreadPoolExecutor
        before = self.initialize()
        folders = []
        reports = self.repo / 'target/surefire-reports'
        reports.mkdir(parents=True)
        for name, production in [('OwnerTest', 'Owner'), ('OtherTest', 'Other')]:
            folder = self.repo / '.makevn' / name
            folder.mkdir()
            stamp = folder / 'stamp'
            stamp.touch()
            (reports / ('TEST-' + name + '.xml')).write_text(
                '<testsuite><testcase classname="example.' + name + '"/></testsuite>')
            (folder / '1.log').write_text(''.join(
                '[0.1s][info][class,load] example.' + item + ' source: file:/fixture/classes/\n'
                for item in [name, production]))
            folders.append((folder, stamp))
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = [executor.submit(progressive.enrich, self.repo, self.repo, self.java,
                                       before, stamp, folder) for folder, stamp in folders]
            for result in results:
                result.result()
        self.assertEqual(progressive.load(self.repo)['observations'],
                         {'example.OwnerTest': ['example.Owner'], 'example.OtherTest': ['example.Other']})

    def test_unavailable_observer_preserves_original_failure_log_exactly(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'pom.xml').write_text('<project/>')
            result = subprocess.run(
                [sys.executable, str(Path(observer.__file__)), folder, folder, str(self.java),
                 sys.executable, '-c', 'import sys; print("original failure", file=sys.stderr); sys.exit(7)'],
                capture_output=True, text=True)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, 'original failure\n')

    def test_observer_preserves_failure_and_does_not_enrich(self):
        result = observer.run(self.repo, self.repo, self.java, [sys.executable, '-c', 'raise SystemExit(7)'])
        self.assertEqual(result, 7)
        self.assertEqual(progressive.load(self.repo)['observations'], {})


if __name__ == '__main__':
    unittest.main()
