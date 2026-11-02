"""Exercise cross-module static selection and additive runtime evidence."""
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

    def test_core_edit_selects_consumers_without_unrelated_tests(self):
        self.edit()
        self.assertEqual(self.plan(), 'app\texample.FeatureTest\ncore\texample.FeatureTest\nservice\texample.FeatureTest')
        self.assertFalse((self.repo / '.makevn').exists())

    def test_prepared_plan_ignores_empty_changed_test_list(self):
        self.edit()
        self.assertEqual(self.plan(self.source, ''), self.plan(self.source))

    def test_test_fixture_edit_retains_downstream_suites(self):
        path = 'core/src/test/java/example/Fixture.java'
        self.write(path, 'package example; class Fixture {}')
        self.commit()
        self.write(path, 'package example; class Fixture { int x; }')
        self.assertEqual(self.plan(path), 'app\t*\ncore\t*\nservice\t*')

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
        self.assertEqual(self.plan(), 'app\t*\ncore\t*\nservice\t*')


if __name__ == '__main__':
    unittest.main()
