"""Neutral reactor/resource fixtures: no Maven, network or company conventions."""
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec/makevn/common'))
spec = importlib.util.spec_from_file_location('scope', ROOT / 'libexec/makevn/common/changes_scope.py')
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)


class ImpactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = pathlib.Path(self.temp.name)
        self.base = self.repo / 'workspace'
        self.write('pom.xml', '<groupId>example</groupId><artifactId>root</artifactId><version>1</version><packaging>pom</packaging><modules><module>contracts</module><module>adapter</module><module>runner</module><module>unrelated</module></modules>')
        self.write('contracts/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>contracts</artifactId><packaging>pom</packaging><modules><module>event</module></modules>')
        self.contract = self.parent('contracts', '../pom.xml') + '<artifactId>event</artifactId><properties><wire.version>1</wire.version></properties><dependencies><dependency><groupId>external</groupId><artifactId>wire</artifactId><version>${wire.version}</version></dependency></dependencies>'
        self.write('contracts/event/pom.xml', self.contract)
        self.write('adapter/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>adapter</artifactId>' + self.dependency('event'))
        self.write('runner/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>runner</artifactId>' + self.dependency('adapter'))
        self.write('unrelated/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>unrelated</artifactId>')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.commit()

    def write(self, name, body):
        path = self.base / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('<project>' + body + '</project>')

    def parent(self, artifact, relative):
        return '<parent><groupId>example</groupId><artifactId>' + artifact + '</artifactId><version>1</version><relativePath>' + relative + '</relativePath></parent>'

    def dependency(self, artifact):
        return '<dependencies><dependency><groupId>${project.groupId}</groupId><artifactId>' + artifact + '</artifactId></dependency></dependencies>'

    def commit(self):
        subprocess.run(['git', '-C', str(self.repo), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.org', 'commit', '-qm', 'fixture'], check=True)

    def mapping(self, **overrides):
        rule = dict(path='workspace/src/test/resources/shared', modules=['adapter', 'runner'], externalChecks=[])
        rule.update(overrides)
        (self.repo / 'makevn-impact.json').write_text(json.dumps(dict(version=1, sharedResources=[rule])))

    def plan(self, *paths):
        return scope.focused_plan(self.repo, self.base, 'HEAD', list(paths))

    def bump(self, extra=''):
        self.write('contracts/event/pom.xml', self.contract.replace('<wire.version>1', '<wire.version>2') + extra)

    def test_leaf_version_bump_selects_owner_and_transitive_consumers(self):
        self.bump()
        self.assertEqual(self.plan('workspace/contracts/event/pom.xml'), 'adapter\t*\ncontracts/event\t*\nrunner\t*')

    def test_shared_resources_require_explicit_scope_and_keep_full_suites(self):
        path = 'workspace/src/test/resources/shared/v2/schema.avsc'
        with self.assertRaises(ValueError):
            self.plan(path)
        self.mapping()
        self.assertEqual(self.plan(path, 'workspace/src/test/resources/shared/examples.yml'), 'adapter\t*\nrunner\t*')
        with self.assertRaises(ValueError):
            self.plan('workspace/src/test/resources/shared-other/schema.avsc')

    def test_resource_mapping_rejects_external_checks(self):
        self.mapping(externalChecks=['external integration suite'])
        with self.assertRaisesRegex(ValueError, 'external integration suite'):
            self.plan('workspace/src/test/resources/shared/schema.avsc')

    def test_invalid_mapping_fails_closed(self):
        for override in [dict(modules=[]), dict(modules=['missing']), dict(modules=['contracts']), dict(modules=['../adapter']), dict(path='../outside'), dict(path='workspace'), dict(path='workspace/src/main/resources'), dict(externalChecks='suite'), dict(unknown=True)]:
            with self.subTest(override=override):
                self.mapping(**override)
                with self.assertRaises(ValueError):
                    self.plan('workspace/src/test/resources/shared/schema.avsc')

    def test_model_changes_and_unknown_properties_remain_unknown(self):
        for body in [self.contract.replace('<artifactId>event', '<artifactId>renamed'), self.contract.replace('<wire.version>1', '<wire.version>2') + '<configuration>${wire.version}</configuration>']:
            self.write('contracts/event/pom.xml', body)
            with self.assertRaises(ValueError):
                self.plan('workspace/contracts/event/pom.xml')

    def test_ambiguous_reactor_coordinates_and_profile_overrides_rejected(self):
        self.bump()
        for body in [self.parent('root', '../pom.xml') + '<artifactId>adapter</artifactId>', self.parent('root', '../pom.xml') + '<artifactId>unrelated</artifactId><profiles><profile><properties><dep.group>different</dep.group></properties></profile></profiles><dependencies><dependency><groupId>${dep.group}</groupId><artifactId>event</artifactId></dependency></dependencies>']:
            self.write('unrelated/pom.xml', body)
            with self.assertRaises(ValueError):
                self.plan('workspace/contracts/event/pom.xml')

    def test_plugin_unpack_outside_owner_requires_shared_mapping(self):
        plugin = '<build><plugins><plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-dependency-plugin</artifactId><configuration><outputDirectory>../../src/test/resources/shared</outputDirectory><artifactItems><artifactItem><groupId>external</groupId><artifactId>wire</artifactId><version>${wire.version}</version></artifactItem></artifactItems></configuration></plugin></plugins></build>'
        self.write('contracts/event/pom.xml', self.contract + plugin)
        self.commit()
        self.bump(plugin)
        with self.assertRaises(ValueError):
            self.plan('workspace/contracts/event/pom.xml')
        self.mapping()
        self.assertEqual(self.plan('workspace/contracts/event/pom.xml'), 'adapter\t*\ncontracts/event\t*\nrunner\t*')

    def test_profile_dependencies_are_overselected_and_managed_only_are_not(self):
        self.write('unrelated/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>unrelated</artifactId><profiles><profile>' + self.dependency('event') + '</profile></profiles>')
        self.bump()
        self.assertIn('unrelated\t*', self.plan('workspace/contracts/event/pom.xml'))
        self.write('unrelated/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>unrelated</artifactId><dependencyManagement>' + self.dependency('event') + '</dependencyManagement>')
        self.assertNotIn('unrelated', self.plan('workspace/contracts/event/pom.xml'))

    def test_inheritance_without_dependency_is_also_selected(self):
        self.write('unrelated/pom.xml', self.parent('event', '../contracts/event/pom.xml') + '<artifactId>unrelated</artifactId>')
        self.bump()
        self.assertIn('unrelated\t*', self.plan('workspace/contracts/event/pom.xml'))

    def test_deleted_fixture_and_overlapping_rules_union_owners(self):
        self.mapping(modules=['adapter'])
        config = self.repo / 'makevn-impact.json'
        data = json.loads(config.read_text())
        data['sharedResources'].append(dict(path='workspace/src/test/resources/shared/v2', modules=['runner'], externalChecks=[]))
        config.write_text(json.dumps(data))
        self.assertEqual(self.plan('workspace/src/test/resources/shared/v2/deleted.avsc'), 'adapter\t*\nrunner\t*')

    def test_symlinked_resource_prefix_and_config_rejected(self):
        self.mapping()
        shared = self.base / 'src/test/resources/shared'
        shared.parent.mkdir(parents=True)
        shared.symlink_to(self.base / 'adapter', target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Shared resource paths'):
            self.plan('workspace/src/test/resources/shared/schema.avsc')
        shared.unlink()
        config = self.repo / 'makevn-impact.json'
        config.rename(self.repo / 'other.json')
        config.symlink_to(self.repo / 'other.json')
        with self.assertRaisesRegex(ValueError, 'linked'):
            self.plan('workspace/src/test/resources/shared/schema.avsc')

    def test_unresolved_coordinates_and_missing_declared_modules_rejected(self):
        self.bump()
        self.write('adapter/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>adapter</artifactId>' + self.dependency('event').replace('${project.groupId}', '${unknown.group}'))
        with self.assertRaisesRegex(ValueError, 'Unresolved'):
            self.plan('workspace/contracts/event/pom.xml')
        (self.base / 'unrelated/pom.xml').unlink()
        with self.assertRaises(ValueError):
            self.plan('workspace/contracts/event/pom.xml')

    def test_duplicate_keys_cannot_override_external_checks(self):
        (self.repo / 'makevn-impact.json').write_text('{"version":1,"sharedResources":[],"sharedResources":[]}')
        with self.assertRaisesRegex(ValueError, 'Duplicate impact'):
            self.plan('workspace/src/test/resources/shared/schema.avsc')

    def test_backend_planner_process_success_and_actionable_rejection(self):
        self.bump()
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/changes_scope.py'), str(self.repo), str(self.base), 'HEAD', '--focused-plan']
        result = subprocess.run(command, input='workspace/contracts/event/pom.xml\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'adapter\t*\ncontracts/event\t*\nrunner\t*')
        result = subprocess.run(command, input='workspace/src/test/resources/shared/schema.avsc\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('No declared shared-resource scope', result.stderr)
        self.assertIn('makevn-impact.json', result.stderr)
        self.mapping(externalChecks=['browser E2E'])
        result = subprocess.run(command, input='workspace/src/test/resources/shared/schema.avsc\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('browser E2E', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_mapping_cannot_hide_java_or_build_changes(self):
        self.mapping()
        for path in ['workspace/src/main/java/A.java', 'workspace/build.sh', 'makevn-impact.json']:
            with self.assertRaises(ValueError):
                self.plan(path)


if __name__ == '__main__':
    unittest.main()
