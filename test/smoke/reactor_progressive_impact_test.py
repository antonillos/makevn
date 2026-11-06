"""Exercise cross-module static selection and additive runtime evidence."""
import contextlib
import io
import json
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
import changes_scope
import observe_test_impact as observer
import progressive_impact as progressive
import reactor_test_impact as reactor
import test_impact as impact


class ReactorProgressiveTests(unittest.TestCase):
    def setUp(self):
        java = shutil.which('java')
        if not java:
            self.skipTest('JDK required')
        self.java = Path(java)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name).resolve()
        self.owners = ['core', 'service', 'app', 'unrelated']
        self.write('pom.xml', '<project><groupId>example</groupId><artifactId>root</artifactId>'
                   '<version>1</version><packaging>pom</packaging><modules>' +
                   ''.join('<module>' + name + '</module>' for name in self.owners) + '</modules></project>')
        for owner, dependency in [('core', ''), ('service', 'core'), ('app', 'service'), ('unrelated', '')]:
            dependencies = ('<dependencies><dependency><groupId>example</groupId><artifactId>' + dependency +
                            '</artifactId><version>1</version></dependency></dependencies>') if dependency else ''
            self.write(owner + '/pom.xml', '<project><parent><groupId>example</groupId><artifactId>root</artifactId>'
                       '<version>1</version></parent><artifactId>' + owner + '</artifactId>' + dependencies + '</project>')
        self.source = 'core/src/main/java/example/Owner.java'
        self.original = 'package example; class Owner { int value() { return 1; } }'
        self.write(self.source, self.original)
        self.write('service/src/main/java/example/Consumer.java', 'package example; class Consumer { Owner owner; }')
        self.write('app/src/main/java/example/Application.java', 'package example; class Application { Consumer consumer; }')
        for owner, target in [('core', 'Owner'), ('service', 'Consumer'), ('app', 'Application'), ('unrelated', 'Other')]:
            self.write(owner + '/src/test/java/example/FeatureTest.java',
                       'package example; class FeatureTest { ' + target + ' target; }')
            self.write(owner + '/src/test/java/example/UnrelatedTest.java',
                       'package example; class UnrelatedTest {}')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.commit()
        environment = patch.dict(os.environ, MAKEVN_TEST_IMPACT_JAVA=str(self.java))
        environment.start()
        self.addCleanup(environment.stop)
        context = patch.object(impact, 'context', return_value={'java': 'fixture', 'environment': {}})
        context.start()
        self.addCleanup(context.stop)

    def write(self, path, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def commit(self):
        subprocess.run(['git', '-C', str(self.repo), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.org',
                        'commit', '--no-gpg-sign', '-qm', 'fixture'], check=True)

    def initialize(self, write=True):
        return progressive.initialize(self.repo, self.repo, self.java, write)

    def edit(self):
        self.write(self.source, self.original.replace('return 1', 'return 2'))

    def plan(self, *paths):
        with contextlib.redirect_stderr(io.StringIO()):
            return changes_scope.focused_plan(self.repo, self.repo, 'HEAD', list(paths or [self.source]))

    def observe(self, before, owner='service', report='active', trace=True):
        stamp = self.repo / '.makevn/stamp'
        stamp.parent.mkdir(exist_ok=True)
        stamp.touch()
        self.write(owner + '/target/surefire-reports/TEST-feature.xml',
                   '<testsuite><testcase classname="example.FeatureTest">' +
                   {'active': '', 'skipped': '<skipped message="optional"/>', 'failed': '<failure/>'}[report] +
                   '</testcase></testsuite>')
        traces = self.repo / '.makevn/traces'
        traces.mkdir(exist_ok=True)
        for old in traces.glob('*.log'):
            old.unlink()
        if trace:
            self.write('.makevn/traces/123.log',
                       '[0.1s][info][class,load] example.FeatureTest source: file:/fixture/test-classes/\n'
                       '[0.1s][info][class,load] example.Owner source: file:/fixture/classes/\n')
        progressive.enrich(self.repo, self.repo, self.java, before, stamp, traces)

    def test_init_and_preview_qualify_duplicate_test_names(self):
        value = self.initialize(False)
        self.assertFalse((self.repo / '.makevn').exists())
        self.assertEqual(value['kind'], reactor.KIND)
        self.assertEqual(len(progressive.tests(value['facts'])), 8)
        self.initialize()
        self.assertIn('core::example.FeatureTest', progressive.load(self.repo)['facts'][
            'core/src/test/java/example/FeatureTest.java']['class'])

    def test_additional_roots_preview_requires_complete_consumer_suites(self):
        pom = self.repo / 'core/pom.xml'
        plugin = ('<build><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                  '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                  '<goals><goal>add-source</goal></goals><configuration><sources>'
                  '<source>${project.build.directory}/generated-sources/event</source>'
                  '<source>extra/java</source></sources></configuration></execution></executions>'
                  '</plugin></plugins></build>')
        pom.write_text(pom.read_text().replace('</project>', plugin + '</project>'))
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/progressive_impact.py'),
                   'preview', str(self.repo), str(self.repo), str(self.java)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan['status'], 'requires_exhaustive_scope')
        self.assertEqual({item['root'] for item in plan['roots']},
                         {'core/target/generated-sources/event', 'core/extra/java'})
        self.assertEqual(plan['suites'], ['app', 'core', 'service'])
        self.assertFalse(plan['tests_executed'])
        self.assertFalse((self.repo / '.makevn').exists())
        self.edit()
        self.assertEqual(self.plan(), 'app\t*\ncore\t*\nservice\t*')
        command[2] = 'init'
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_additional_roots_preview_reports_unresolved_expression(self):
        pom = self.repo / 'core/pom.xml'
        plugin = ('<build><plugins><plugin><artifactId>build-helper-maven-plugin</artifactId>'
                  '<executions><execution><goals><goal>add-source</goal></goals>'
                  '<configuration><sources><source>${unknown}/generated</source></sources>'
                  '</configuration></execution></executions></plugin></plugins></build>')
        pom.write_text(pom.read_text().replace('</project>', plugin + '</project>'))
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/progressive_impact.py'),
                   'preview', str(self.repo), str(self.repo), str(self.java)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        plan = json.loads(result.stdout)
        self.assertEqual(plan['status'], 'unsupported')
        self.assertEqual(plan['unresolved_roots'][0]['root'], '${unknown}/generated')
        self.assertEqual(plan['suites'], [])
        self.assertIn('--exhaustive', plan['next_action'])

    def test_custom_build_directory_leaves_source_expression_unresolved(self):
        pom = self.repo / 'core/pom.xml'
        plugin = ('<build><directory>build-output</directory><plugins><plugin>'
                  '<groupId>org.codehaus.mojo</groupId><artifactId>build-helper-maven-plugin</artifactId>'
                  '<executions><execution><goals><goal>add-source</goal></goals><configuration><sources>'
                  '<source>${project.build.directory}/generated</source></sources></configuration>'
                  '</execution></executions></plugin></plugins></build>')
        pom.write_text(pom.read_text().replace('</project>', plugin + '</project>'))
        result = reactor.additional_roots_preview(self.repo, reactor.modules(self.repo))
        self.assertEqual(result['status'], 'unsupported')
        self.assertEqual(result['unresolved_roots'][0]['root'], '${project.build.directory}/generated')

    def test_inherited_additional_root_is_not_assigned_to_one_owner(self):
        pom = self.repo / 'pom.xml'
        plugin = ('<build><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                  '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                  '<goals><goal>add-source</goal></goals><configuration><sources>'
                  '<source>extra/java</source></sources></configuration></execution></executions>'
                  '</plugin></plugins></build>')
        pom.write_text(pom.read_text().replace('</project>', plugin + '</project>'))
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/progressive_impact.py'),
                   'preview', str(self.repo), str(self.repo), str(self.java)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        plan = json.loads(result.stdout)
        self.assertEqual(plan['status'], 'unsupported')
        self.assertIn('extra/java', [item['root'] for item in plan['unresolved_roots']])
        self.assertEqual(plan['suites'], [])

    def test_inherited_generated_roots_require_child_consumer_suites(self):
        pom = self.repo / 'pom.xml'
        plugin = ('<build><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                  '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                  '<goals><goal>add-source</goal></goals><configuration><sources>'
                  '<source>target/generated-sources/openapi/src/gen/java/main</source>'
                  '</sources></configuration></execution></executions></plugin></plugins></build>')
        pom.write_text(pom.read_text().replace('</project>', plugin + '</project>'))
        plan = reactor.additional_roots_preview(self.repo, reactor.modules(self.repo))
        self.assertEqual(plan['status'], 'requires_exhaustive_scope', plan)
        self.assertEqual({item['root'] for item in plan['roots']},
                         {owner + '/target/generated-sources/openapi/src/gen/java/main' for owner in self.owners})
        self.assertEqual(plan['suites'], sorted(self.owners))
        self.assertFalse(plan['tests_executed'])
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/progressive_impact.py'),
                   'preview', str(self.repo), str(self.repo), str(self.java)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'requires_exhaustive_scope')
        self.assertFalse((self.repo / '.makevn').exists())

    def test_inherited_generated_roots_cross_nested_aggregator(self):
        self.write('api/pom.xml', '<project><parent><groupId>example</groupId>'
                   '<artifactId>root</artifactId><version>1</version></parent>'
                   '<artifactId>api</artifactId><packaging>pom</packaging>'
                   '<modules><module>generated</module></modules></project>')
        self.write('api/generated/pom.xml', '<project><parent><groupId>example</groupId>'
                   '<artifactId>api</artifactId><version>1</version></parent>'
                   '<artifactId>generated</artifactId></project>')
        root = self.repo / 'pom.xml'
        root.write_text(root.read_text().replace('<module>core</module>',
                   '<module>api</module><module>core</module>'))
        plugin = ('<build><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                  '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                  '<goals><goal>add-source</goal></goals><configuration><sources>'
                  '<source>${project.build.directory}/generated-sources/schema/java</source>'
                  '</sources></configuration></execution></executions></plugin></plugins></build>')
        api = self.repo / 'api/pom.xml'
        api.write_text(api.read_text().replace('</project>', plugin + '</project>'))
        service = self.repo / 'service/pom.xml'
        service.write_text(service.read_text().replace('</dependencies>',
                           '<dependency><groupId>example</groupId><artifactId>generated</artifactId>'
                           '<version>1</version></dependency></dependencies>'))
        plan = reactor.additional_roots_preview(self.repo, reactor.modules(self.repo))
        self.assertEqual(plan['status'], 'requires_exhaustive_scope', plan)
        self.assertEqual({item['root'] for item in plan['roots']},
                         {'api/generated/target/generated-sources/schema/java'})
        self.assertEqual(plan['suites'], ['api/generated', 'app', 'service'])
        self.assertFalse(plan['tests_executed'])

    def test_inherited_generated_build_directory_and_unknown_suffix(self):
        pom = self.repo / 'pom.xml'
        original = pom.read_text()
        plugin = ('<build><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                  '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                  '<goals><goal>add-source</goal></goals><configuration><sources>'
                  '<source>${project.build.directory}/generated-sources/api</source>'
                  '</sources></configuration></execution></executions></plugin></plugins></build>')
        pom.write_text(original.replace('</project>', plugin + '</project>'))
        plan = reactor.additional_roots_preview(self.repo, reactor.modules(self.repo))
        self.assertEqual(plan['status'], 'requires_exhaustive_scope', plan)
        self.assertEqual({item['root'] for item in plan['roots']},
                         {owner + '/target/generated-sources/api' for owner in self.owners})

        pom.write_text(pom.read_text().replace('generated-sources/api',
                                               'generated-sources/${generator.output}'))
        plan = reactor.additional_roots_preview(self.repo, reactor.modules(self.repo))
        self.assertEqual(plan['status'], 'unsupported')
        self.assertEqual(plan['unresolved_roots'][0]['root'],
                         '${project.build.directory}/generated-sources/${generator.output}')
        self.assertEqual(plan['suites'], [])

    def test_inherited_generated_root_with_child_plugin_override_is_unresolved(self):
        pom = self.repo / 'pom.xml'
        plugin = ('<build><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                  '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                  '<id>generated</id><goals><goal>add-source</goal></goals>'
                  '<configuration><sources><source>target/generated-sources/api</source>'
                  '</sources></configuration></execution></executions></plugin></plugins></build>')
        pom.write_text(pom.read_text().replace('</project>', plugin + '</project>'))
        child = self.repo / 'core/pom.xml'
        override = ('<build><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                    '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                    '<id>generated</id><configuration combine.self="override"><sources>'
                    '<source>${generator.output}</source></sources></configuration>'
                    '</execution></executions></plugin></plugins></build>')
        child.write_text(child.read_text().replace('</project>', override + '</project>'))
        plan = reactor.additional_roots_preview(self.repo, reactor.modules(self.repo))
        self.assertEqual(plan['status'], 'unsupported')
        self.assertIn('target/generated-sources/api',
                      [item['root'] for item in plan['unresolved_roots']])
        self.assertEqual(plan['roots'], [])
        self.assertEqual(plan['suites'], [])
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/progressive_impact.py'),
                   'preview', str(self.repo), str(self.repo), str(self.java)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['status'], 'unsupported')

    def test_managed_generated_source_plugin_has_no_child_owner(self):
        pom = self.repo / 'pom.xml'
        plugin = ('<build><pluginManagement><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                  '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                  '<goals><goal>add-source</goal></goals><configuration><sources>'
                  '<source>target/generated-sources/api</source></sources></configuration>'
                  '</execution></executions></plugin></plugins></pluginManagement></build>')
        pom.write_text(pom.read_text().replace('</project>', plugin + '</project>'))
        plan = reactor.additional_roots_preview(self.repo, reactor.modules(self.repo))
        self.assertEqual(plan['status'], 'unsupported')
        self.assertEqual(plan['roots'], [])
        self.assertIn('target/generated-sources/api',
                      [item['root'] for item in plan['unresolved_roots']])

    def test_noninherited_generated_source_execution_has_no_child_owner(self):
        pom = self.repo / 'pom.xml'
        plugin = ('<build><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                  '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                  '<inherited>false</inherited><goals><goal>add-source</goal></goals>'
                  '<configuration><sources><source>target/generated-sources/api</source>'
                  '</sources></configuration></execution></executions></plugin></plugins></build>')
        pom.write_text(pom.read_text().replace('</project>', plugin + '</project>'))
        plan = reactor.additional_roots_preview(self.repo, reactor.modules(self.repo))
        self.assertEqual(plan['status'], 'unsupported')
        self.assertEqual(plan['roots'], [])
        self.assertIn('target/generated-sources/api',
                      [item['root'] for item in plan['unresolved_roots']])

    def test_parent_profile_override_keeps_generated_root_unresolved(self):
        pom = self.repo / 'pom.xml'
        plugin = ('<build><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                  '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                  '<id>generated</id><goals><goal>add-source</goal></goals>'
                  '<configuration><sources><source>target/generated-sources/api</source>'
                  '</sources></configuration></execution></executions></plugin></plugins></build>')
        profile = ('<profiles><profile><id>alternate</id><activation><activeByDefault>true</activeByDefault>'
                   '</activation><build><plugins><plugin><groupId>org.codehaus.mojo</groupId>'
                   '<artifactId>build-helper-maven-plugin</artifactId><executions><execution>'
                   '<id>generated</id><configuration><sources>'
                   '<source>target/generated-sources/other</source></sources></configuration>'
                   '</execution></executions></plugin></plugins></build></profile></profiles>')
        pom.write_text(pom.read_text().replace('</project>', plugin + profile + '</project>'))
        plan = reactor.additional_roots_preview(self.repo, reactor.modules(self.repo))
        self.assertEqual(plan['status'], 'unsupported')
        self.assertEqual(plan['roots'], [])
        self.assertIn('target/generated-sources/api',
                      [item['root'] for item in plan['unresolved_roots']])

    def test_core_edit_selects_consumers_without_unrelated_tests(self):
        self.edit()
        self.assertEqual(self.plan(), 'app\texample.FeatureTest\ncore\texample.FeatureTest\nservice\texample.FeatureTest')
        self.assertFalse((self.repo / '.makevn').exists())

    def test_prepared_plan_ignores_empty_changed_test_list(self):
        self.edit()
        self.assertEqual(self.plan(self.source, ''), self.plan(self.source))

    def test_all_inventory_accepted_changed_tests_are_retained(self):
        for name in ['ITAdditional', 'TestAdditional', 'AdditionalChecks']:
            with self.subTest(name=name):
                path = 'core/src/test/java/example/' + name + '.java'
                annotation = '@Test ' if name == 'AdditionalChecks' else ''
                content = 'package example; class ' + name + ' { ' + annotation + 'void check() { assert true; } }'
                self.write(path, content)
                self.commit()
                self.edit()
                self.write(path, content.replace('assert true', 'assert false'))
                core = dict(line.split('\t') for line in self.plan(self.source, path).splitlines())['core']
                self.assertEqual(set(core.split(',')), {'example.FeatureTest', 'example.' + name})
                (self.repo / path).unlink()
                self.write(self.source, self.original)

    def test_test_fixture_edit_retains_downstream_suites(self):
        path = 'core/src/test/java/example/Fixture.java'
        self.write(path, 'package example; class Fixture {}')
        self.commit()
        self.write(path, 'package example; class Fixture { int x; }')
        self.assertEqual(self.plan(path), 'app\t*\ncore\t*\nservice\t*')

    def test_shared_test_superclass_edit_retains_downstream_consumers(self):
        path = 'core/src/test/java/example/FixtureTest.java'
        content = 'package example; class FixtureTest { int fixtureValue() { return 1; } }'
        self.write(path, content)
        self.write('service/src/test/java/example/FeatureTest.java',
                   'package example; class FeatureTest extends FixtureTest { '
                   '@Test void check() { assert fixtureValue() == 1; } }')
        self.write('service/src/test/java/example/OptionalTest.java',
                   'package example; @Disabled class OptionalTest { @Test void check() {} }')
        core_pom = self.repo / 'core/pom.xml'
        core_pom.write_text(core_pom.read_text().replace('</project>',
                            '<build><plugins><plugin><artifactId>maven-jar-plugin</artifactId>'
                            '<executions><execution><goals><goal>test-jar</goal></goals></execution></executions>'
                            '</plugin></plugins></build></project>'))
        service_pom = self.repo / 'service/pom.xml'
        service_pom.write_text(service_pom.read_text().replace('</dependencies>',
                               '<dependency><groupId>example</groupId><artifactId>core</artifactId>'
                               '<version>1</version><type>test-jar</type><classifier>tests</classifier>'
                               '<scope>test</scope></dependency></dependencies>'))
        self.commit()
        self.write(path, content.replace('return 1', 'return 2'))
        plan = dict(line.split('\t') for line in self.plan(path).splitlines())
        self.assertEqual(plan['core'], 'example.FixtureTest')
        self.assertEqual(set(plan['service'].split(',')), {'example.FeatureTest', 'example.OptionalTest'})

    def test_module_resource_change_retains_downstream_suites(self):
        path = 'core/src/main/resources/settings.properties'
        self.write(path, 'changed=true')
        self.assertEqual(self.plan(path), 'app\t*\ncore\t*\nservice\t*')

    def test_runtime_observations_use_report_owner_and_are_additive(self):
        before = self.initialize()
        self.observe(before)
        value = progressive.load(self.repo)
        self.assertEqual(value['observations'], {'service::example.FeatureTest': ['core::example.Owner']})
        self.edit()
        self.assertIn('app\texample.FeatureTest', self.plan())
        self.assertEqual(self.initialize()['observations'], value['observations'])

    def test_failed_or_untraced_reports_do_not_add_edges(self):
        before = self.initialize()
        with self.assertRaisesRegex(ValueError, 'failed reports'):
            self.observe(before, report='failed')
        self.assertEqual(progressive.load(self.repo)['observations'], {})
        self.observe(before, trace=False)
        self.assertEqual(progressive.load(self.repo)['observations'], {})

    def test_optional_reports_are_scoped_to_module(self):
        before = self.initialize()
        self.observe(before, report='skipped')
        self.assertEqual(progressive.load(self.repo)['skipped'], {'service::example.FeatureTest': 'optional'})
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/selected_test_reports.py')]
        stamp = self.repo / '.makevn/stamp'
        result = subprocess.run(command + [str(self.repo / 'service'), 'example.FeatureTest', str(stamp), str(self.repo)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.write('core/target/surefire-reports/TEST-feature.xml',
                   '<testsuite><testcase classname="example.FeatureTest"><skipped/></testcase></testsuite>')
        result = subprocess.run(command + [str(self.repo / 'core'), 'example.FeatureTest', str(stamp), str(self.repo)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)

    def test_normal_execution_runs_once_and_enriches_reactor(self):
        code = '''
import os
from pathlib import Path
root = Path.cwd()
directory = root / 'service/target/surefire-reports'
directory.mkdir(parents=True)
(directory / 'TEST-feature.xml').write_text('<testsuite><testcase classname="example.FeatureTest"/></testsuite>')
traces = Path(os.environ['JAVA_TOOL_OPTIONS'].split('file=')[1].split('/%p.log')[0])
(traces / '123.log').write_text('[0.1s][info][class,load] example.FeatureTest source: file:/fixture/test-classes/\\n'
                              '[0.1s][info][class,load] example.Owner source: file:/fixture/classes/\\n')
with (root / '.makevn/calls').open('a') as calls:
    calls.write('run\\n')
'''
        command = [sys.executable, '-c', 'import os; os.chdir(' + repr(str(self.repo)) + ');' + code]
        self.assertEqual(observer.run(self.repo, self.repo, self.java, command), 0)
        self.assertEqual((self.repo / '.makevn/calls').read_text(), 'run\n')
        self.assertEqual(progressive.load(self.repo)['observations'],
                         {'service::example.FeatureTest': ['core::example.Owner']})

    def test_profile_membership_is_not_guessed(self):
        root = self.repo / 'pom.xml'
        root.write_text(root.read_text().replace('</project>', '<profiles><profile><modules>'
                        '<module>conditional</module></modules></profile></profiles></project>'))
        with self.assertRaisesRegex(ValueError, 'profile-dependent'):
            self.initialize()

    def test_configuration_and_membership_changes_invalidate_observations(self):
        before = self.initialize()
        self.observe(before)
        self.write('service/src/test/resources/ignored.properties', 'changed=true')
        self.assertEqual(self.initialize()['observations'], {})
        before = self.initialize()
        self.observe(before)
        self.write('unrelated/pom.xml', (self.repo / 'unrelated/pom.xml').read_text().replace('unrelated', 'renamed'))
        self.assertEqual(self.initialize()['observations'], {})

    def test_generated_and_custom_filters_keep_consumer_suites(self):
        self.edit()
        self.write('service/target/generated-sources/example/Generated.java', 'class Generated {}')
        self.assertEqual(self.plan(), 'app\t*\ncore\t*\nservice\t*')
        shutil.rmtree(self.repo / 'service/target')
        pom = self.repo / 'service/pom.xml'
        pom.write_text(pom.read_text().replace('</project>', '<build><plugins><plugin>'
                       '<artifactId>maven-surefire-plugin</artifactId><configuration><includes>'
                       '<include>**/*Checks.java</include></includes></configuration></plugin></plugins></build></project>'))
        with self.assertRaises(changes_scope.ExhaustiveScopeRequired):
            self.plan(self.source, 'service/pom.xml')
        self.write(self.source, self.original)
        self.commit()
        self.edit()
        self.assertEqual(self.plan(), 'app\texample.FeatureTest\ncore\texample.FeatureTest\nservice\t*')

    def add_filter(self, owner):
        pom = self.repo / owner / 'pom.xml'
        pom.write_text(pom.read_text().replace('</project>', '<build><plugins><plugin>'
                       '<artifactId>maven-surefire-plugin</artifactId><configuration><excludes>'
                       '<exclude>**/*SlowTest.java</exclude></excludes></configuration></plugin></plugins></build></project>'))

    def test_unrelated_module_filters_do_not_block_selection(self):
        self.add_filter('unrelated')
        self.commit()
        self.edit()
        self.assertEqual(self.plan(), 'app\texample.FeatureTest\ncore\texample.FeatureTest\nservice\texample.FeatureTest')

    def test_module_filters_affect_only_their_owner_and_real_children(self):
        self.add_filter('core')
        pom = self.repo / 'service/pom.xml'
        pom.write_text(pom.read_text().replace('<artifactId>root</artifactId>', '<artifactId>core</artifactId>')
                       .replace('</parent>', '<relativePath>../core/pom.xml</relativePath></parent>'))
        self.commit()
        self.edit()
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            plan = changes_scope.focused_plan(self.repo, self.repo, 'HEAD', [self.source])
        self.assertEqual(plan, 'app\texample.FeatureTest\ncore\t*\nservice\t*')
        self.assertEqual(output.getvalue().count('configured test inventory'), 1)
        self.assertIn('complete suites for core, service;', output.getvalue())

    def test_shared_parent_filter_has_one_grouped_fallback(self):
        self.add_filter('.')
        self.commit()
        self.edit()
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            plan = changes_scope.focused_plan(self.repo, self.repo, 'HEAD', [self.source])
        self.assertEqual(plan, 'app\t*\ncore\t*\nservice\t*')
        self.assertEqual(output.getvalue().count('configured test inventory'), 1)
        self.assertIn('complete suites for app, core, service;', output.getvalue())


if __name__ == '__main__':
    unittest.main()
