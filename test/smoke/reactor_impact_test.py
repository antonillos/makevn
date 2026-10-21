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

    def all_suites(self):
        return 'adapter\t*\ncontracts\t*\ncontracts/event\t*\nrunner\t*\nunrelated\t*'

    def legacy_mapping(self, **overrides):
        rule = dict(path='workspace/src/test/resources/shared', modules=['adapter', 'runner'], externalChecks=[])
        rule.update(overrides)
        (self.repo / 'makevn-impact.json').write_text(json.dumps(dict(version=1, sharedResources=[rule])))

    def plan(self, *paths):
        return scope.focused_plan(self.repo, self.base, 'HEAD', list(paths))

    def bump(self, extra=''):
        self.write('contracts/event/pom.xml', self.contract.replace('<wire.version>1', '<wire.version>2') + extra)

    def assert_exhaustive_outcome(self, path):
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/changes_scope.py'), str(self.repo), str(self.base), 'HEAD']
        result = subprocess.run(command, input=path + '\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '.')
        result = subprocess.run(command + ['--focused-plan'], input=path + '\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertIn('--exhaustive', result.stderr)
        script = r'''
set -euo pipefail
SCRIPT_DIR="$1/libexec/makevn"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/commands/changes.sh"
makevn_detect_maven_base_path() { printf '%s/workspace' "$1"; }
makevn_maven_executable() { printf unused; }
makevn_effective_local_containers() { :; }
makevn_detect_parent_branch_spec() { printf HEAD; }
makevn_refresh_impact() { :; }
makevn_load_profile() { :; }
makevn_frontend_owns_loader() { return 0; }
if [[ "$3" == preview ]]; then
  cmd_verify_changes_preview "$2"
else
  makevn_collect_verify_changes_scope "$2"
fi
'''
        command = ['bash', '-c', script, 'test', str(ROOT), str(self.repo)]
        result = subprocess.run(command + ['preview'], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('requires exhaustive scope', result.stdout)
        self.assertIn('no tests ran', result.stdout)
        self.assertFalse(self.repo.joinpath('.makevn/verify-changes-plan.env').exists())
        result = subprocess.run(command + ['execute'], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_leaf_version_bump_selects_owner_and_transitive_consumers(self):
        self.bump()
        self.assertEqual(self.plan('workspace/contracts/event/pom.xml'), 'adapter\t*\ncontracts/event\t*\nrunner\t*')

    def test_local_maven_plugin_consumers_are_in_reverse_closure(self):
        packaging = '<packaging>maven-plugin</packaging>'
        self.write('contracts/event/pom.xml', self.contract + packaging)
        self.commit()
        plugin = '<plugin><groupId>example</groupId><artifactId>event</artifactId><version>1</version></plugin>'
        for wrapper in ['<build><plugins>{}</plugins></build>',
                        '<profiles><profile><build><plugins>{}</plugins></build></profile></profiles>']:
            with self.subTest(wrapper=wrapper):
                self.write('unrelated/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>unrelated</artifactId>' + wrapper.format(plugin))
                self.bump(packaging)
                self.assertIn('unrelated\t*', self.plan('workspace/contracts/event/pom.xml'))
        self.write('unrelated/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>unrelated</artifactId><build><pluginManagement><plugins>' + plugin + '</plugins></pluginManagement></build>')
        self.assertNotIn('unrelated', self.plan('workspace/contracts/event/pom.xml'))

    def test_local_build_extension_consumers_and_inheritors_are_selected(self):
        extension = '<build><extensions><extension><groupId>example</groupId><artifactId>event</artifactId><version>1</version></extension></extensions></build>'
        self.write('adapter/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>adapter</artifactId>')
        self.write('unrelated/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>unrelated</artifactId>' + extension)
        self.write('runner/pom.xml', self.parent('unrelated', '../unrelated/pom.xml') + '<artifactId>runner</artifactId>')
        self.commit()
        self.bump()
        self.assertEqual(self.plan('workspace/contracts/event/pom.xml'), 'contracts/event\t*\nrunner\t*\nunrelated\t*')

    def test_root_build_extension_consumer_requires_exhaustive_scope(self):
        root = self.base / 'pom.xml'
        root.write_text(root.read_text().replace('</project>', '<build><extensions><extension><groupId>example</groupId><artifactId>event</artifactId><version>1</version></extension></extensions></build></project>'))
        self.commit()
        self.bump()
        with self.assertRaisesRegex(scope.ExhaustiveScopeRequired, 'Maven-root consumer'):
            self.plan('workspace/contracts/event/pom.xml')
        self.assert_exhaustive_outcome('workspace/contracts/event/pom.xml')

    def test_shared_resources_default_to_complete_reactor_suites(self):
        path = 'workspace/src/test/resources/shared/v2/schema.avsc'
        self.assertEqual(self.plan(path), self.all_suites())
        self.legacy_mapping()
        self.assertEqual(self.plan(path, 'workspace/src/test/resources/shared/examples.yml', 'workspace/src/test/resources/shared/src/nested.avsc'), self.all_suites())
        self.assertEqual(self.plan('workspace/src/test/resources/shared-other/schema.avsc'), self.all_suites())

    def test_legacy_external_declaration_cannot_change_automatic_scope(self):
        self.legacy_mapping(externalChecks=['external integration suite'])
        self.assertEqual(self.plan('workspace/src/test/resources/shared/schema.avsc'), self.all_suites())

    def test_legacy_root_configuration_is_not_read(self):
        for override in [dict(modules=[]), dict(modules=['missing']), dict(modules=['contracts']), dict(modules=['../adapter']), dict(path='../outside'), dict(path='workspace'), dict(path='workspace/src/main/resources'), dict(externalChecks='suite'), dict(unknown=True)]:
            with self.subTest(override=override):
                self.legacy_mapping(**override)
                self.assertEqual(self.plan('workspace/src/test/resources/shared/schema.avsc'), self.all_suites())

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

    def test_plugin_unpack_shared_output_uses_automatic_scope_without_mapping(self):
        plugin = '<build><plugins><plugin><groupId>org.apache.maven.plugins</groupId><artifactId>maven-dependency-plugin</artifactId><configuration><outputDirectory>../../src/test/resources/shared</outputDirectory><artifactItems><artifactItem><groupId>external</groupId><artifactId>wire</artifactId><version>${wire.version}</version></artifactItem></artifactItems></configuration></plugin></plugins></build>'
        self.write('contracts/event/pom.xml', self.contract + plugin)
        self.commit()
        self.bump(plugin)
        self.assertEqual(self.plan('workspace/contracts/event/pom.xml'), self.all_suites())
        self.legacy_mapping()
        self.assertEqual(self.plan('workspace/contracts/event/pom.xml'), self.all_suites())

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

    def test_legacy_overlapping_rules_cannot_narrow_deleted_fixture_scope(self):
        self.legacy_mapping(modules=['adapter'])
        config = self.repo / 'makevn-impact.json'
        data = json.loads(config.read_text())
        data['sharedResources'].append(dict(path='workspace/src/test/resources/shared/v2', modules=['runner'], externalChecks=[]))
        config.write_text(json.dumps(data))
        self.assertEqual(self.plan('workspace/src/test/resources/shared/v2/deleted.avsc'), self.all_suites())

    def test_linked_fixture_is_rejected_but_legacy_config_is_not_read(self):
        self.legacy_mapping()
        shared = self.base / 'src/test/resources/shared'
        shared.parent.mkdir(parents=True)
        shared.symlink_to(self.base / 'adapter', target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'linked'):
            self.plan('workspace/src/test/resources/shared/schema.avsc')
        shared.unlink()
        config = self.repo / 'makevn-impact.json'
        config.rename(self.repo / 'other.json')
        config.symlink_to(self.repo / 'other.json')
        self.assertEqual(self.plan('workspace/src/test/resources/shared/schema.avsc'), self.all_suites())

    def test_unresolved_coordinates_and_missing_declared_modules_rejected(self):
        self.bump()
        self.write('adapter/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>adapter</artifactId>' + self.dependency('event').replace('${project.groupId}', '${unknown.group}'))
        with self.assertRaisesRegex(ValueError, 'Unresolved'):
            self.plan('workspace/contracts/event/pom.xml')
        (self.base / 'unrelated/pom.xml').unlink()
        with self.assertRaises(ValueError):
            self.plan('workspace/contracts/event/pom.xml')

    def test_malformed_legacy_root_json_cannot_override_automatic_scope(self):
        (self.repo / 'makevn-impact.json').write_text('{"version":1,"sharedResources":[],"sharedResources":[]}')
        self.assertEqual(self.plan('workspace/src/test/resources/shared/schema.avsc'), self.all_suites())

    def test_backend_planner_process_success_and_actionable_rejection(self):
        self.bump()
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/changes_scope.py'), str(self.repo), str(self.base), 'HEAD', '--focused-plan']
        result = subprocess.run(command, input='workspace/contracts/event/pom.xml\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'adapter\t*\ncontracts/event\t*\nrunner\t*')
        result = subprocess.run(command, input='workspace/src/test/resources/shared/schema.avsc\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), self.all_suites())
        self.legacy_mapping(externalChecks=['browser E2E'])
        result = subprocess.run(command, input='workspace/src/test/resources/shared/schema.avsc\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), self.all_suites())

    def test_non_pom_filename_does_not_gain_contract_classification(self):
        other = self.base / 'contracts/event/alternate-pom.xml'
        other.write_text('<project>' + self.contract + '</project>')
        self.commit()
        other.write_text(other.read_text().replace('<wire.version>1', '<wire.version>2'))
        with self.assertRaises(ValueError):
            self.plan('workspace/contracts/event/alternate-pom.xml')

    def test_generated_state_refreshes_reactor_and_is_never_trusted(self):
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/changes_scope.py'), str(self.repo), str(self.base), 'HEAD', '--impact-state', str(self.repo / '.makevn/impact.json')]
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.repo / '.makevn/impact.json'
        data = json.loads(state.read_text())
        self.assertEqual(data['origin'], 'generated')
        self.assertEqual(data['strategy'], 'all-reactor-suites')
        state.write_text('{"modules": ["adapter"]}')
        self.assertEqual(self.plan('workspace/src/test/resources/shared/schema.avsc'), self.all_suites())
        root = self.base / 'pom.xml'
        root.write_text(root.read_text().replace('<module>unrelated</module>', '<module>additional</module>'))
        self.write('additional/pom.xml', self.parent('root', '../pom.xml') + '<artifactId>additional</artifactId>')
        subprocess.run(command, text=True, capture_output=True, check=True)
        self.assertIn('additional', json.loads(state.read_text())['modules'])
        self.assertNotIn('unrelated', json.loads(state.read_text())['modules'])
        self.assertIn('additional\t*', self.plan('workspace/src/test/resources/shared/schema.avsc'))

    def test_unclassifiable_root_still_rejects_automatic_resource_scope(self):
        for body in [ '<artifactId>root</artifactId><packaging>jar</packaging>', '<artifactId>root</artifactId><packaging>pom</packaging><profiles><profile><modules><module>adapter</module></modules></profile></profiles>' ]:
            self.write('pom.xml', body)
            with self.assertRaises(ValueError):
                self.plan('workspace/src/test/resources/shared/schema.avsc')

    def test_root_test_code_cannot_be_skipped_by_automatic_scope(self):
        path = self.base / 'src/test/custom/RootTests.txt'
        path.parent.mkdir(parents=True)
        path.touch()
        resource = self.base / 'src/test/resources/shared/schema.avsc'
        resource.parent.mkdir(parents=True)
        resource.write_text('original')
        self.commit()
        resource.write_text('changed')
        with self.assertRaises(scope.ExhaustiveScopeRequired):
            self.plan('workspace/src/test/resources/shared/schema.avsc')
        self.assert_exhaustive_outcome('workspace/src/test/resources/shared/schema.avsc')

    def test_nested_planner_xml_and_io_failures_remain_errors(self):
        self.bump()
        command = [sys.executable, str(ROOT / 'libexec/makevn/common/changes_scope.py'),
                   str(self.repo), str(self.base), 'HEAD', '--focused-plan']
        pom = self.base / 'contracts/event/pom.xml'
        for broken in ['<broken', None]:
            with self.subTest(broken=broken):
                if broken is None:
                    pom.unlink()
                else:
                    pom.write_text(broken)
                result = subprocess.run(command, input='workspace/contracts/event/pom.xml\n', text=True, capture_output=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn('Focused scope unavailable', result.stderr)

    def test_mapping_cannot_hide_java_or_build_changes(self):
        self.legacy_mapping()
        for path in ['workspace/src/main/java/A.java', 'workspace/build.sh', 'makevn-impact.json']:
            with self.assertRaises(ValueError):
                self.plan(path)


if __name__ == '__main__':
    unittest.main()
