"""Impact selection and invalidation tests without Maven or network access."""
import contextlib
import hashlib
import io
import json
import os
import re
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
import zipfile
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
            self.facts[path] = {'class': 'example.' + name, 'shape': 'same', 'names': names,
                                'bodies': [{'hash': 'baseline', 'writes': False}]}
            compiled = self.repo / ('target/test-classes/' if name.endswith('Test') else 'target/classes/') / ('example/' + name + '.class')
            compiled.parent.mkdir(parents=True, exist_ok=True)
            compiled.write_bytes(name.encode())
        self.addCleanup(patch.stopall)
        patch.object(impact, 'context', return_value={'java': 'fixture'}).start()
        patch.object(impact, 'repository_models', return_value={}).start()
        patch('progressive_impact.absorb_isolated').start()
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

    def test_initialization_is_noop_only_for_complete_identical_map(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertTrue(impact.capture_status(self.repo, self.repo, Path('java')))
        self.assertIn('no-op', output.getvalue())
        (self.repo / self.source).write_text('changed')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(impact.capture_status(self.repo, self.repo, Path('java')))

    def test_first_capture_explains_missing_evidence_without_reuse_error(self):
        (impact.state(self.repo) / 'map.json').unlink()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertFalse(impact.capture_status(self.repo, self.repo, Path('java')))
        self.assertIn('no previous evidence', output.getvalue())
        self.assertNotIn('cannot reuse', output.getvalue())
        with contextlib.redirect_stderr(io.StringIO()) as output:
            impact.retire_capture(self.repo, self.repo, Path('java'))
        self.assertIn('no previous map', output.getvalue())
        self.assertNotIn('cannot reuse', output.getvalue())

    def test_pending_map_reports_previous_incomplete_capture(self):
        impact.save(impact.state(self.repo) / 'map.json',
                    {'version': impact.VERSION, 'status': 'pending'})
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertFalse(impact.capture_status(self.repo, self.repo, Path('java')))
        self.assertIn('previous capture did not complete', output.getvalue())
        self.assertNotIn('altered', output.getvalue())
        with contextlib.redirect_stderr(io.StringIO()) as output:
            impact.retire_capture(self.repo, self.repo, Path('java'))
        self.assertIn('previous capture did not complete', output.getvalue())
        self.assertNotIn('altered', output.getvalue())

    def test_skipped_optional_class_is_published_without_record_and_always_selected(self):
        stamp = self.repo / 'stamp'
        stamp.touch()
        reports = self.repo / 'target/surefire-reports'
        reports.mkdir(parents=True)
        reports.joinpath('TEST-active.xml').write_text(
            '<testsuite><testcase classname="example.OwnerTest"/></testsuite>')
        reports.joinpath('TEST-optional.xml').write_text(
            '<testsuite><testcase classname="example.OtherTest"><skipped '
            'message="optional property missing"/></testcase></testsuite>')
        with contextlib.redirect_stdout(io.StringIO()) as output:
            impact.begin(self.repo, self.repo, Path('java'), stamp)
        self.assertEqual(output.getvalue().strip(), 'example.OwnerTest')
        path = impact.state(self.repo) / 'capture.json'
        value = impact.sealed_load(path)
        self.assertEqual(value['skipped'], {'example.OtherTest': ['optional property missing']})
        value['records'] = {'example.OwnerTest': ['example.Owner']}
        impact.sealed_save(path, value)
        impact.finish(self.repo, self.repo, Path('java'))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(impact.capture_status(self.repo, self.repo, Path('java')))
        (self.repo / self.source).write_text('changed body')
        selected, _ = self.plan()
        self.assertEqual(selected, {'example.OwnerTest', 'example.OtherTest'})
        with patch.object(impact, 'context', return_value={'java': 'changed'}):
            self.assertIsNone(self.plan()[0])

    def test_all_skipped_baseline_cannot_seed_map(self):
        stamp = self.repo / 'stamp'
        stamp.touch()
        report = self.repo / 'target/surefire-reports/TEST-example.OwnerTest.xml'
        report.parent.mkdir(parents=True)
        report.write_text('<testsuite><testcase classname="example.OwnerTest"><skipped/></testcase></testsuite>')
        with self.assertRaisesRegex(ValueError, 'no fresh complete-suite'):
            impact.report_inventory(self.repo, stamp, {})

    def test_partially_skipped_class_is_active_and_always_retained(self):
        stamp = self.repo / 'stamp'
        stamp.touch()
        report = self.repo / 'target/surefire-reports/TEST-example.OwnerTest.xml'
        report.parent.mkdir(parents=True)
        report.write_text('<testsuite><testcase classname="example.OwnerTest"/>'
                          '<testcase classname="example.OwnerTest"><skipped/></testcase></testsuite>')
        skipped = {}
        self.assertEqual(impact.report_inventory(self.repo, stamp, skipped), ['example.OwnerTest'])
        self.assertEqual(skipped, {'example.OwnerTest': ['no reason reported']})

    def test_optional_inventory_change_restarts_checkpoint(self):
        self.checkpoint()
        value = impact.sealed_load(impact.state(self.repo) / 'capture.json')
        value['skipped'] = {'example.OptionalTest': ['disabled']}
        impact.sealed_save(impact.state(self.repo) / 'capture.json', value)
        self.assertEqual(self.begin_capture(),
                         ['example.ConsumerTest', 'example.OtherTest', 'example.OwnerTest'])

    def checkpoint(self):
        value = dict(self.value)
        value['status'] = 'pending'
        value['records'] = {'example.OwnerTest': ['example.Owner']}
        impact.sealed_save(impact.state(self.repo) / 'capture.json', value)

    def begin_capture(self):
        with patch.object(impact, 'report_inventory', return_value=self.value['tests']), contextlib.redirect_stdout(io.StringIO()) as output:
            impact.begin(self.repo, self.repo, Path('java'), self.repo / 'stamp')
        return output.getvalue().strip().splitlines()

    def test_recording_retires_map_but_preserves_compatible_completed_records(self):
        impact.retire_capture(self.repo, self.repo, Path('java'))
        self.assertIsNone(self.plan()[0])
        self.assertEqual(self.begin_capture(), [])
        impact.finish(self.repo, self.repo, Path('java'))
        self.assertIsNotNone(self.plan()[0])

    def test_resuming_checkpoint_runs_only_missing_classes(self):
        self.checkpoint()
        self.assertEqual(self.begin_capture(), ['example.ConsumerTest', 'example.OtherTest'])
        self.assertEqual(impact.sealed_load(impact.state(self.repo) / 'capture.json')['records'],
                         {'example.OwnerTest': ['example.Owner']})
        self.assertIsNone(self.plan()[0])

    def test_incompatible_or_corrupt_checkpoint_restarts_all_classes(self):
        for change in ['source', 'bytecode', 'jar', 'seal']:
            with self.subTest(change=change):
                self.checkpoint()
                path = impact.state(self.repo) / 'capture.json'
                value = impact.sealed_load(path)
                if change == 'source':
                    value['inputs'][self.source] = 'old'
                elif change == 'bytecode':
                    value['bytecode']['target/classes/example/Owner.class'] = 'old'
                elif change == 'jar':
                    value['jars'] = {str(self.repo / 'missing.jar'): 'old'}
                impact.sealed_save(path, value)
                if change == 'seal':
                    value['records'] = {}
                    impact.save(path, value)
                self.assertEqual(self.begin_capture(), sorted(self.value['tests']))

    def test_incomplete_checkpoint_cannot_be_published(self):
        self.checkpoint()
        with self.assertRaisesRegex(ValueError, 'incomplete isolated'):
            impact.finish(self.repo, self.repo, Path('java'))

    def test_consumer_index_preserves_collisions_cycles_and_dynamic_callers(self):
        sources = {
            'a': {'class': 'one.Owner', 'names': ['Consumer']},
            'b': {'class': 'two.Owner', 'names': []},
            'c': {'class': 'example.Consumer', 'names': ['Owner']},
            'd': {'class': 'example.Dynamic', 'names': ['forName']},
            'e': {'class': 'example.DynamicTest', 'names': ['Dynamic']},
            'f': {'class': 'example.Unrelated', 'names': []},
        }
        self.assertEqual(impact.impacted_classes(sources, {'one.Owner', 'two.Owner'}),
                         {'one.Owner', 'two.Owner', 'example.Consumer', 'example.Dynamic', 'example.DynamicTest'})

    def test_consumer_index_does_not_rescan_sources_for_each_chain_step(self):
        class Sources(dict):
            scans = 0

            def values(self):
                self.scans += 1
                return super().values()

        sources = Sources({str(index): {'class': 'example.Type' + str(index),
                                       'names': ['Type' + str(index - 1)]}
                           for index in range(2000)})
        result = impact.impacted_classes(sources, {'example.Type0'})
        self.assertEqual(len(result), 2000)
        self.assertEqual(sources.scans, 1)

    def test_changed_test_is_always_included(self):
        selected, _ = self.plan([self.source, 'src/test/java/example/OtherTest.java'], {'example.OtherTest'})
        self.assertEqual(selected, set(self.value['tests']))

    def test_dynamic_test_and_dynamic_production_consumers_are_included(self):
        self.facts['src/main/java/example/Other.java']['names'] = ['forName']
        selected, _ = self.plan()
        self.assertEqual(selected, set(self.value['tests']))

    def test_unknown_dynamic_changed_class_falls_back(self):
        for name in ['ServiceLoader', 'System', 'FileWriter', 'RandomAccessFile']:
            with self.subTest(name=name):
                self.facts[self.source]['names'] = [name]
                selected, diagnostic = self.plan()
                self.assertIsNone(selected)
                self.assertIn('dynamic', diagnostic)

    def test_removed_global_effect_in_baseline_retains_complete_suite(self):
        self.value['facts'][self.source]['names'] = ['System', 'clearProperty']
        self.value['facts'][self.source]['bodies'] = [{'hash': 'clear property', 'writes': False}]
        self.write_map()
        self.facts[self.source]['bodies'] = [{'hash': 'no cleanup', 'writes': False}]
        selected, diagnostic = self.plan()
        self.assertIsNone(selected)
        self.assertIn('global-state', diagnostic)

    def test_shared_state_writes_do_not_exclude_tests_of_the_written_class(self):
        self.value['records']['example.OwnerTest'] = ['example.Owner', 'example.Other']
        self.write_map()
        self.facts[self.source]['names'] = ['Other']
        self.facts[self.source]['bodies'] = [{'hash': 'Other.flag = -1', 'writes': True}]
        selected, diagnostic = self.plan()
        self.assertIsNone(selected)
        self.assertIn('shared Java state', diagnostic)

    def test_unchanged_constructor_writes_do_not_disable_method_body_selection(self):
        self.value['facts'][self.source]['bodies'] = [
            {'hash': 'constructor', 'writes': True}, {'hash': 'old body', 'writes': False}]
        self.write_map()
        self.facts[self.source]['bodies'] = [
            {'hash': 'constructor', 'writes': True}, {'hash': 'new body', 'writes': False}]
        self.assertIsNotNone(self.plan()[0])
        self.value['facts'][self.source]['bodies'][1]['writes'] = True
        self.write_map()
        self.assertIsNone(self.plan()[0])

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

    def test_literal_unmatched_quote_in_serialized_profile_uses_actual_word_splitting(self):
        profile = self.repo / '.makevn/profile.env'
        profile.parent.mkdir(exist_ok=True)
        profile.write_text(r'MAKEVN_PROFILE_COMPILE_PROP_FLAGS=-Dmaven.site.skip=true\ -Dmaven.javadoc.skip=true\"' + '\n')
        impact.validate_layout(self.repo)
        profile.write_text(r'MAKEVN_PROFILE_VERIFY_CLI_FLAGS=-Dlabel=\"\ -s\ /tmp/settings.xml' + '\n')
        with self.assertRaisesRegex(ValueError, 'custom Maven settings'):
            impact.validate_layout(self.repo)

    def test_serialized_settings_overrides_cannot_seed_or_reuse_impact_evidence(self):
        profile = self.repo / '.makevn/profile.env'
        variants = [
            'MAKEVN_PROFILE_VERIFY_CLI_FLAGS="-s /tmp/settings.xml"',
            r'MAKEVN_PROFILE_VERIFY_CLI_FLAGS=-s\ /tmp/settings.xml',
            'MAKEVN_PROFILE_VERIFY_CLI_FLAGS="-Dlabel=#literal -s /tmp/settings.xml"',
            r'MAKEVN_PROFILE_VERIFY_CLI_FLAGS=-Dlabel=#literal\ -s\ /tmp/settings.xml',
            "MAKEVN_PROFILE_VERIFY_CLI_FLAGS='-Dlabel=\" -s /tmp/settings.xml\"'",
            'MAKEVN_PROFILE_MAVEN_CLI_FLAGS="-gs /tmp/settings.xml"',
            r'MAKEVN_PROFILE_VERIFY_CLI_FLAGS=-gs\ /tmp/settings.xml',
            'MAKEVN_PROFILE_VERIFY_CLI_FLAGS="-s/tmp/settings.xml"',
            'MAKEVN_PROFILE_VERIFY_CLI_FLAGS="--settings=/tmp/settings.xml"',
            'MAKEVN_PROFILE_VERIFY_CLI_FLAGS="--global-settings /tmp/settings.xml"',
            'MAKEVN_PROFILE_VERIFY_PROP_FLAGS="-Dmaven.repo.local=/tmp/repository"',
        ]
        for serialized in variants:
            with self.subTest(serialized=serialized):
                profile.write_text(serialized + '\n')
                self.value['inputs'] = impact.inputs(self.repo, self.repo)
                self.write_map()
                with self.assertRaisesRegex(ValueError, 'custom Maven settings'):
                    impact.validate_layout(self.repo)
                selected, diagnostic = self.plan()
                self.assertIsNone(selected)
                self.assertIn('custom Maven settings', diagnostic)

    def test_generated_profile_cannot_hide_external_settings_changes(self):
        with tempfile.NamedTemporaryFile(mode='w', suffix='.xml') as settings:
            flags = '-s ' + settings.name
            generated = subprocess.check_output(
                ['bash', '-c', 'printf "MAKEVN_PROFILE_VERIFY_CLI_FLAGS=%q\\n" "$1"', 'profile', flags], text=True)
            (self.repo / '.makevn/profile.env').write_text(generated)
            self.value['inputs'] = impact.inputs(self.repo, self.repo)
            self.write_map()
            for content in ['<settings/>', '<settings><activeProfiles><activeProfile>other</activeProfile></activeProfiles></settings>']:
                settings.seek(0)
                settings.truncate()
                settings.write(content)
                settings.flush()
                selected, diagnostic = self.plan()
                self.assertIsNone(selected)
                self.assertIn('custom Maven settings', diagnostic)

    def test_ordinary_serialized_flags_remain_eligible_and_other_sources_are_checked(self):
        (self.repo / '.makevn/profile.env').write_text(
            'MAKEVN_PROFILE_MAVEN_CLI_FLAGS=-B\\ -nsu\nMAKEVN_PROFILE_VERIFY_CLI_FLAGS="-Ptest -Dexample=true"\n')
        self.value['inputs'] = impact.inputs(self.repo, self.repo)
        self.write_map()
        self.assertIsNotNone(self.plan()[0])
        maven_config = self.repo / '.mvn/maven.config'
        maven_config.parent.mkdir()
        maven_config.write_text('-s\n/tmp/settings.xml\n')
        with self.assertRaisesRegex(ValueError, 'custom Maven settings'):
            impact.validate_layout(self.repo)
        maven_config.unlink()
        for variable, flags in [('MAVEN_ARGS', '-gs /tmp/settings.xml'), ('MAVEN_OPTS', '-Dmaven.repo.local=/tmp/repository')]:
            with self.subTest(variable=variable), patch.dict(os.environ, {variable: flags}):
                with self.assertRaisesRegex(ValueError, 'custom Maven settings'):
                    impact.validate_layout(self.repo)

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

    def test_changed_cached_model_cannot_be_hidden_by_recording_another_class(self):
        self.checkpoint()
        path = impact.state(self.repo) / 'capture.json'
        value = impact.sealed_load(path)
        value['models'] = {'parent.pom': 'baseline'}
        impact.sealed_save(path, value)
        trace = impact.state(self.repo) / 'traces'
        trace.mkdir()
        (trace / '1.log').write_text('[0.1s][info][class,load] example.OtherTest source: file:/fixture/test-classes/\n')
        with self.assertRaisesRegex(ValueError, 'model changed'):
            impact.record(self.repo, self.repo, 'example.OtherTest', trace)
        self.assertNotIn('example.OtherTest', impact.sealed_load(path)['records'])

    def test_isolated_trace_requires_the_selected_test_jvm(self):
        value = dict(self.value)
        value['records'] = {}
        impact.sealed_save(impact.state(self.repo) / 'capture.json', value)
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
        report.write_text('<testsuite><testcase classname="example.OwnerTest"><skipped message="optional property missing"/></testcase></testsuite>')
        with self.assertRaisesRegex(ValueError, 'skipped') as raised:
            impact.report_inventory(self.repo, stamp)
        self.assertIn('example.OwnerTest', str(raised.exception))
        self.assertIn('optional property missing', str(raised.exception))
        self.assertIn(str(report), str(raised.exception))
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
        self.assertEqual(self.plan()[0], {'example.ConsumerTest', 'example.OwnerTest'})

    def test_generated_sources_and_new_compiled_classes_fall_back(self):
        generated = self.repo / 'target/generated-sources/example/New.java'
        generated.parent.mkdir(parents=True)
        generated.write_text('class New {}')
        self.assertIsNone(self.plan()[0])
        generated.unlink()
        (self.repo / 'target/classes/example/Owner$New.class').write_bytes(b'new')
        self.assertIsNone(self.plan()[0])

    def test_rebuilt_project_archive_reuses_map_but_rejects_resource_or_bytecode_drift(self):
        jar = self.repo / 'target/project.jar'
        def package(resource=b'stable', compiled=b'Owner'):
            with zipfile.ZipFile(jar, 'w') as archive:
                archive.writestr('example/Owner.class', compiled)
                archive.writestr('settings.properties', resource)
        package()
        self.value['owned_jars'] = {str(jar): impact.owned_archive(self.repo, jar)}
        self.write_map()
        compiled = self.repo / 'target/classes/example/Owner.class'
        compiled.write_bytes(b'new method body')
        package(compiled=b'new method body')
        self.assertIsNotNone(self.plan()[0])
        package(resource=b'changed', compiled=b'new method body')
        self.assertIsNone(self.plan()[0])
        package(compiled=b'stale class')
        self.assertIsNone(self.plan()[0])


class CaptureLockTests(unittest.TestCase):
    def test_concurrent_capture_is_rejected_and_lock_is_released(self):
        import fcntl
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / '.makevn/test-impact'
            state.mkdir(parents=True)
            script = root / 'backend.sh'
            script.write_text('exit 0\n')
            command = [sys.executable, str(ROOT / 'libexec/makevn/common/test_impact_lock.py'),
                       str(root), str(script), 'test-impact-init']
            with (state / 'capture.lock').open('w') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                blocked = subprocess.run(command, capture_output=True, text=True)
                self.assertNotEqual(blocked.returncode, 0)
                self.assertIn('already running', blocked.stderr)
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)


class JavaSourceFactsTests(unittest.TestCase):
    def java(self):
        java = shutil.which('java')
        if java is None:
            self.skipTest('Java unavailable')
        result = subprocess.run([java, '--version'], capture_output=True, text=True)
        version = re.search(r'(?:openjdk|java) (\d+)', result.stdout)
        if not version or int(version[1]) < 17:
            self.skipTest('JDK 17+ unavailable')
        return Path(java)

    def test_parser_distinguishes_method_bodies_from_contracts_and_initializers(self):
        java = self.java()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'src/main/java/Owner.java'
            source.parent.mkdir(parents=True)
            source.write_text('class Owner { int value = 1; int read() { return value; } }')
            before = impact.facts(root, java)
            source.write_text('class Owner { int value = 1; int read() { int copy = value; return copy; } }')
            body = impact.facts(root, Path(java))
            self.assertEqual(before['src/main/java/Owner.java']['shape'], body['src/main/java/Owner.java']['shape'])
            source.write_text('class Owner { int value = 2; int read() { return value; } }')
            self.assertNotEqual(before['src/main/java/Owner.java']['shape'],
                                impact.facts(root, Path(java))['src/main/java/Owner.java']['shape'])
            source.write_text('class Owner { int value = 1; long read() { return value; } }')
            self.assertNotEqual(before['src/main/java/Owner.java']['shape'],
                                impact.facts(root, Path(java))['src/main/java/Owner.java']['shape'])

    def test_parser_detects_field_array_compound_and_unary_writes_in_changed_methods(self):
        java = self.java()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'src/main/java/Owner.java'
            source.parent.mkdir(parents=True)
            prefix = 'class Owner { int value; Owner() { this.value = 1; } int read() { '
            source.write_text(prefix + 'return value; } }')
            before = impact.facts(root, java)['src/main/java/Owner.java']
            self.assertTrue(before['bodies'][0]['writes'])
            source.write_text(prefix + 'final int copy = value; return copy; } }')
            self.assertFalse(impact.state_writes_changed(before, impact.facts(root, java)['src/main/java/Owner.java']))
            for statement in ['Other.flag = -1;', 'Other.flag += 1;', 'Other.flag++;',
                              '--Other.flag;', 'Other.flags[0] = -1;', 'value = 2;']:
                with self.subTest(statement=statement):
                    source.write_text(prefix + statement + ' return value; } }')
                    after = impact.facts(root, java)['src/main/java/Owner.java']
                    self.assertTrue(impact.state_writes_changed(before, after))
                    self.assertTrue(impact.state_writes_changed(after, before))


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
                    impact.os.environ, {'CODEX_TOOL_CALL_ID': 'one', 'TOKEN': 'private fixture',
                                        'SHELLOPTS': 'errexit:nounset'}, clear=True):
                before = impact.context(java)
                impact.os.environ['CODEX_TOOL_CALL_ID'] = 'two'
                impact.os.environ['SHELLOPTS'] = 'nounset'
                self.assertEqual(before, impact.context(java))
                self.assertNotIn('private fixture', json.dumps(before))
                impact.os.environ['TOKEN'] = 'changed fixture'
                self.assertNotEqual(before, impact.context(java))


if __name__ == '__main__':
    unittest.main()
