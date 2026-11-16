"""Validate owner ancestry without inspecting sibling filters or fetching POMs."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec/makevn/common'))
import test_inventory as inventory


class TestInventoryTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        self.base = self.home / 'workspace'
        for context in [patch.object(Path, 'home', return_value=self.home),
                        patch.dict(os.environ, MAVEN_CONFIG=str(self.home / '.m2'))]:
            context.start()
            self.addCleanup(context.stop)

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def parent(self, artifact, relative=''):
        return ('<parent><groupId>example</groupId><artifactId>' + artifact + '</artifactId>'
                '<version>1</version><relativePath>' + relative + '</relativePath></parent>')

    def model(self, artifact, parent='', filters=False):
        configuration = ('<build><plugins><plugin><artifactId>maven-failsafe-plugin</artifactId>'
                         '<configuration><includesFile>test-patterns.txt</includesFile></configuration>'
                         '</plugin></plugins></build>') if filters else ''
        return ('<project><groupId>example</groupId><artifactId>' + artifact + '</artifactId>'
                '<version>1</version>' + parent + configuration + '</project>')

    def cached(self, artifact, **options):
        path = self.home / '.m2/repository/example' / artifact / '1' / (artifact + '-1.pom')
        self.write(path, self.model(artifact, **options))

    def test_cached_parent_filters_are_inherited_transitively(self):
        self.write(self.base / 'pom.xml', self.model('child', self.parent('published')))
        self.cached('published', parent=self.parent('ancestor'))
        self.cached('ancestor', filters=True)
        with self.assertRaisesRegex(ValueError, 'configured test inventory'):
            inventory.validate(self.base)

    def test_empty_relative_path_does_not_inherit_aggregator(self):
        self.write(self.base / 'pom.xml', self.model('aggregator', filters=True))
        self.write(self.base / 'child/pom.xml', self.model('child', self.parent('published')))
        self.cached('published')
        inventory.validate(self.base, 'child')

    def test_mismatched_local_coordinates_use_declared_cached_parent(self):
        self.write(self.base / 'pom.xml', self.model('aggregator', filters=True))
        self.write(self.base / 'child/pom.xml', self.model('child', self.parent('published', '../pom.xml')))
        self.cached('published')
        inventory.validate(self.base, 'child')

    def test_missing_cached_parent_is_not_assumed_filter_free(self):
        self.write(self.base / 'pom.xml', self.model('child', self.parent('missing')))
        with self.assertRaisesRegex(ValueError, 'unavailable in the local cache'):
            inventory.validate(self.base)

    def test_settings_local_repository_is_respected(self):
        repository = self.home / 'repository'
        self.write(self.home / '.m2/settings.xml', '<settings><localRepository>' + str(repository) + '</localRepository></settings>')
        self.write(repository / 'example/published/1/published-1.pom', self.model('published', filters=True))
        self.write(self.base / 'pom.xml', self.model('child', self.parent('published')))
        with self.assertRaisesRegex(ValueError, 'configured test inventory'):
            inventory.validate(self.base)

    def test_local_parent_cycle_is_rejected(self):
        self.write(self.base / 'pom.xml', self.model('first', self.parent('second', 'second.xml')))
        self.write(self.base / 'second.xml', self.model('second', self.parent('first', 'pom.xml')))
        with self.assertRaisesRegex(ValueError, 'cyclic'):
            inventory.validate(self.base)

    def filtered_model(self, configuration, profile=None):
        plugin = ('<build><plugins><plugin><artifactId>maven-surefire-plugin</artifactId>'
                  '<configuration>' + configuration + '</configuration></plugin></plugins></build>')
        body = plugin if profile is None else '<profiles><profile><id>' + profile + '</id>' + plugin + '</profile></profiles>'
        self.write(self.base / 'pom.xml', self.model('child').replace('</project>', body + '</project>'))

    def test_conventional_includes_and_literal_excludes_respect_selection(self):
        self.filtered_model('<includes><include>**/*Test.java</include></includes>'
                            '<excludes><exclude>**/perf/PerformanceTest.java</exclude></excludes>')
        rules = inventory.validate(self.base)
        names = {'example.OwnerTest', 'example.TestOwner', 'example.perf.PerformanceTest', 'RootTest'}
        self.assertEqual(inventory.eligible(names, rules), {'example.OwnerTest', 'RootTest'})

    def test_profile_filter_reports_pom_profile_and_pattern_location(self):
        self.filtered_model('<excludes><exclude>**/OwnerTest.java</exclude></excludes>', 'conditional')
        with self.assertRaisesRegex(ValueError, r'pom.xml.*profile\[conditional\].*maven-surefire-plugin.*excludes.*activation'):
            inventory.validate(self.base)

    def test_unknown_patterns_and_filter_files_fail_closed_with_context(self):
        for value in ['<includes><include>%regex[.*]</include></includes>',
                      '<excludes><exclude>${excluded}</exclude></excludes>',
                      '<includesFile>filters.txt</includesFile>']:
            with self.subTest(value=value):
                self.filtered_model(value)
                with self.assertRaisesRegex(ValueError, r'pom.xml.*maven-surefire-plugin'):
                    inventory.validate(self.base)

    def test_execution_filters_report_binding_uncertainty(self):
        self.filtered_model('<includes><include>**/*Test.java</include></includes>')
        pom = self.base / 'pom.xml'
        pom.write_text(pom.read_text().replace('<configuration>', '<executions><execution><id>custom-tests</id><configuration>')
                       .replace('</configuration>', '</configuration></execution></executions>'))
        with self.assertRaisesRegex(ValueError, r'execution\[custom-tests\].*binding'):
            inventory.validate(self.base)

    def test_filter_inheritance_merge_is_not_guessed(self):
        self.filtered_model('<includes><include>**/*Test.java</include></includes>')
        pom = self.base / 'pom.xml'
        pom.write_text(pom.read_text().replace('<artifactId>child</artifactId>', '<artifactId>child</artifactId>' + self.parent('parent')))
        parent = self.home / '.m2/repository/example/parent/1/parent-1.pom'
        self.write(parent, self.model('parent').replace('</project>',
                   '<build><plugins><plugin><artifactId>maven-surefire-plugin</artifactId><configuration>'
                   '<includes><include>**/*Tests.java</include></includes></configuration></plugin></plugins></build></project>'))
        with self.assertRaisesRegex(ValueError, 'multiple filter configurations'):
            inventory.validate(self.base)


if __name__ == '__main__':
    unittest.main()
