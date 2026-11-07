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


if __name__ == '__main__':
    unittest.main()
