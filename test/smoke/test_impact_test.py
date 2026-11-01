"""Impact selection and invalidation tests without Maven or network access."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec/makevn/common'))
import test_impact as impact


class TestImpactTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name).resolve()
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c',
                        'user.email=test@example.org', 'commit', '--allow-empty',
                        '--no-gpg-sign', '-qm', 'fixture'], check=True)
        (self.repo / 'pom.xml').write_text('<project/>')
        self.source = 'src/main/java/example/Owner.java'
        self.facts = {}
        for name, names in [('Owner', []), ('Consumer', ['Owner']), ('Other', []),
                            ('OwnerTest', ['Owner']), ('ConsumerTest', ['Consumer']),
                            ('OtherTest', ['Other'])]:
            prefix = 'src/test/java/' if name.endswith('Test') else 'src/main/java/'
            path = prefix + 'example/' + name + '.java'
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('class ' + name + ' {}')
            self.facts[path] = {'class': 'example.' + name, 'shape': 'same', 'names': names}
            compiled = self.repo / ('target/test-classes/' if name.endswith('Test') else 'target/classes/') / ('example/' + name + '.class')
            compiled.parent.mkdir(parents=True, exist_ok=True)
            compiled.write_bytes(name.encode())
        self.addCleanup(patch.stopall)
        patch.object(impact, 'context', return_value={'java': 'fixture'}).start()
        patch.object(impact, 'repository_models', return_value={}).start()
        patch.object(impact, 'facts', side_effect=lambda *_: json.loads(json.dumps(self.facts))).start()
        self.value = {'version': impact.VERSION, 'status': 'success', 'base': str(self.repo),
                      'head': subprocess.check_output(['git', '-C', str(self.repo), 'rev-parse', 'HEAD']).decode().strip(),
                      'inputs': impact.inputs(self.repo, self.repo), 'context': {'java': 'fixture'},
                      'facts': json.loads(json.dumps(self.facts)), 'bytecode': impact.bytecode(self.repo),
                      'tests': ['example.OwnerTest', 'example.ConsumerTest', 'example.OtherTest'],
                      'records': {'example.OwnerTest': ['example.Owner'],
                                  'example.ConsumerTest': ['example.Consumer'],
                                  'example.OtherTest': ['example.Other']}, 'jars': {}, 'models': {}}
        self.write_map()

    def write_map(self):
        value = dict(self.value)
        value['seal'] = hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()
        impact.save(impact.state(self.repo) / 'map.json', value)

    def plan(self, paths=None, tests=None):
        with contextlib.redirect_stderr(io.StringIO()) as output:
            selected = impact.narrow(self.repo, self.repo, '.', paths or [self.source], tests or set())
        return selected, output.getvalue()

    def test_selects_direct_and_transitive_consumers_but_not_unrelated_tests(self):
        (self.repo / self.source).write_text('changed body')
        selected, diagnostic = self.plan()
        self.assertEqual(selected, {'example.OwnerTest', 'example.ConsumerTest'})
        self.assertIn('2/3', diagnostic)

    def test_changed_test_is_always_included(self):
        selected, _ = self.plan([self.source, 'src/test/java/example/OtherTest.java'], {'example.OtherTest'})
        self.assertEqual(selected, set(self.value['tests']))

    def test_dynamic_test_and_dynamic_production_consumers_are_included(self):
        self.facts['src/main/java/example/Other.java']['names'] = ['forName']
        selected, _ = self.plan()
        self.assertEqual(selected, set(self.value['tests']))

    def test_unknown_dynamic_changed_class_falls_back(self):
        self.facts[self.source]['names'] = ['ServiceLoader']
        selected, diagnostic = self.plan()
        self.assertIsNone(selected)
        self.assertIn('dynamic', diagnostic)

    def test_declaration_changes_and_missing_direct_coverage_fall_back(self):
        self.facts[self.source]['shape'] = 'different declaration'
        self.assertIsNone(self.plan()[0])
        self.facts[self.source]['shape'] = 'same'
        self.value['records']['example.OwnerTest'] = []
        self.write_map()
        self.assertIsNone(self.plan()[0])

    def test_changed_test_helper_is_not_treated_as_a_test(self):
        self.assertIsNone(self.plan([self.source, 'src/test/java/example/OtherTest.java'])[0])

    def test_configuration_resource_pom_and_test_inventory_changes_fall_back(self):
        (self.repo / 'pom.xml').write_text('<project><description>new</description></project>')
        self.assertIsNone(self.plan()[0])
        self.assertIsNone(self.plan([self.source, 'pom.xml'])[0])
        (self.repo / 'pom.xml').write_text('<project/>')
        (self.repo / 'src/test/java/example/NewTest.java').write_text('class NewTest {}')
        self.assertIsNone(self.plan()[0])

    def test_pending_altered_missing_and_empty_evidence_fall_back(self):
        path = impact.state(self.repo) / 'map.json'
        path.write_text('{"status":"pending"}')
        self.assertIsNone(self.plan()[0])
        self.write_map()
        value = json.loads(path.read_text())
        value['records']['example.OwnerTest'] = ['example.Other']
        path.write_text(json.dumps(value))
        self.assertIsNone(self.plan()[0])
        path.unlink()
        self.assertIsNone(self.plan()[0])

    def test_bytecode_and_dependency_drift_invalidates(self):
        compiled = self.repo / 'target/classes/example/Other.class'
        compiled.write_bytes(b'external change')
        self.assertIsNone(self.plan()[0])
        compiled.write_bytes(b'Other')
        jar = self.repo / 'dependency.jar'
        jar.write_bytes(b'old')
        self.value['inputs'] = impact.inputs(self.repo, self.repo)
        self.value['jars'][str(jar)] = impact.digest(jar)
        self.write_map()
        jar.write_bytes(b'new')
        self.assertIsNone(self.plan()[0])

    def test_isolated_trace_requires_the_selected_test_jvm(self):
        value = dict(self.value)
        value['records'] = {}
        impact.save(impact.state(self.repo) / 'capture.json', value)
        trace = impact.state(self.repo) / 'traces'
        trace.mkdir()
        (trace / '1.log').write_text('[0.1s][info][class,load] example.Owner source: file:/fixture/target/classes/\n')
        with self.assertRaisesRegex(ValueError, 'missing test JVM'):
            impact.record(self.repo, self.repo, 'example.OwnerTest', trace)
        with (trace / '1.log').open('a') as stream:
            stream.write('[0.1s][info][class,load] example.OwnerTest source: file:/fixture/target/test-classes/\n')
        impact.record(self.repo, self.repo, 'example.OwnerTest', trace)
        value = json.loads((impact.state(self.repo) / 'capture.json').read_text())
        self.assertEqual(value['records'], {'example.OwnerTest': ['example.Owner']})
        with self.assertRaisesRegex(ValueError, 'incomplete isolated'):
            impact.finish(self.repo, self.repo, Path('/fixture/java'))

    def test_failed_skipped_and_stale_suite_reports_cannot_seed_capture(self):
        stamp = self.repo / 'stamp'
        stamp.touch()
        report = self.repo / 'target/surefire-reports/TEST-example.OwnerTest.xml'
        report.parent.mkdir(parents=True)
        report.write_text('<testsuite><testcase classname="example.OwnerTest"><failure/></testcase></testsuite>')
        with self.assertRaisesRegex(ValueError, 'failed'):
            impact.report_inventory(self.repo, stamp)
        report.write_text('<testsuite><testcase classname="example.OwnerTest"><skipped/></testcase></testsuite>')
        with self.assertRaisesRegex(ValueError, 'skipped'):
            impact.report_inventory(self.repo, stamp)
        report.write_text('<testsuite><testcase classname="example.OwnerTest"/></testsuite>')
        self.assertEqual(impact.report_inventory(self.repo, stamp), ['example.OwnerTest'])
        stale_after = report.stat().st_mtime_ns + 1_000_000_000
        os.utime(stamp, ns=(stale_after, stale_after))
        with self.assertRaisesRegex(ValueError, 'no fresh'):
            impact.report_inventory(self.repo, stamp)

    def test_complete_capture_publishes_reusable_map_and_planner_selects_consumers(self):
        stamp = impact.state(self.repo) / 'stamp'
        stamp.touch()
        reports = self.repo / 'target/surefire-reports'
        reports.mkdir()
        for name in self.value['tests']:
            (reports / ('TEST-' + name + '.xml')).write_text(
                '<testsuite><testcase classname="' + name + '"/></testsuite>')
        with contextlib.redirect_stdout(io.StringIO()):
            impact.begin(self.repo, self.repo, Path('/fixture/java'), stamp)
        for name, loaded in self.value['records'].items():
            traces = impact.state(self.repo) / 'traces'
            traces.mkdir(exist_ok=True)
            (traces / '1.log').write_text('\n'.join(
                '[0.1s][info][class,load] ' + cls + ' source: file:/fixture/classes/'
                for cls in [name, *loaded]))
            impact.record(self.repo, self.repo, name, traces)
        impact.finish(self.repo, self.repo, Path('/fixture/java'))
        from changes_scope import focused_plan
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(focused_plan(self.repo, self.repo, 'HEAD', [self.source]),
                             '.\texample.ConsumerTest,example.OwnerTest')

    def test_generated_sources_and_new_compiled_classes_fall_back(self):
        generated = self.repo / 'target/generated-sources/example/New.java'
        generated.parent.mkdir(parents=True)
        generated.write_text('class New {}')
        self.assertIsNone(self.plan()[0])
        generated.unlink()
        (self.repo / 'target/classes/example/Owner$New.class').write_bytes(b'new')
        self.assertIsNone(self.plan()[0])


class JavaSourceFactsTests(unittest.TestCase):
    def test_parser_distinguishes_method_bodies_from_contracts_and_initializers(self):
        java = shutil.which('java')
        if java is None:
            self.skipTest('Java unavailable')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'src/main/java/Owner.java'
            source.parent.mkdir(parents=True)
            source.write_text('class Owner { int value = 1; int read() { return value; } }')
            try:
                before = impact.facts(root, Path(java))
            except ValueError as error:
                self.skipTest('JDK 17+ unavailable: ' + str(error))
            source.write_text('class Owner { int value = 1; int read() { int copy = value; return copy; } }')
            body = impact.facts(root, Path(java))
            self.assertEqual(before['src/main/java/Owner.java']['shape'], body['src/main/java/Owner.java']['shape'])
            source.write_text('class Owner { int value = 2; int read() { return value; } }')
            self.assertNotEqual(before['src/main/java/Owner.java']['shape'],
                                impact.facts(root, Path(java))['src/main/java/Owner.java']['shape'])
            source.write_text('class Owner { int value = 1; long read() { return value; } }')
            self.assertNotEqual(before['src/main/java/Owner.java']['shape'],
                                impact.facts(root, Path(java))['src/main/java/Owner.java']['shape'])


class ContextTests(unittest.TestCase):
    def test_maven_install_timestamps_do_not_hide_version_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'maven-metadata-local.xml'
            path.write_text('<metadata><version>1</version><lastUpdated>1</lastUpdated></metadata>')
            before = impact.model_digest(path)
            path.write_text('<metadata><version>1</version><lastUpdated>2</lastUpdated></metadata>')
            self.assertEqual(before, impact.model_digest(path))
            path.write_text('<metadata><version>2</version><lastUpdated>2</lastUpdated></metadata>')
            self.assertNotEqual(before, impact.model_digest(path))

    def test_environment_fingerprints_hide_values_and_ignore_transient_call_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            java = root / 'jdk/bin/java'
            java.parent.mkdir(parents=True)
            java.touch()
            (root / 'jdk/release').write_text('fixture')
            with patch.object(impact.Path, 'home', return_value=root), patch.dict(
                    impact.os.environ, {'CODEX_TOOL_CALL_ID': 'one', 'TOKEN': 'private fixture'}, clear=True):
                before = impact.context(java)
                impact.os.environ['CODEX_TOOL_CALL_ID'] = 'two'
                self.assertEqual(before, impact.context(java))
                self.assertNotIn('private fixture', json.dumps(before))
                impact.os.environ['TOKEN'] = 'changed fixture'
                self.assertNotEqual(before, impact.context(java))


if __name__ == '__main__':
    unittest.main()
