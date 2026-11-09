import importlib.util
from pathlib import Path
import tempfile
import unittest

path = Path(__file__).resolve().parents[2] / 'libexec/makevn/common/jacoco_signal.py'
spec = importlib.util.spec_from_file_location('jacoco_signal', path)
signal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signal)


class SignalTests(unittest.TestCase):
    def test_parent_profile_declaration_is_found_without_claiming_activation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'pom.xml').write_text('<project><groupId>demo</groupId><artifactId>parent</artifactId><version>1</version><profiles><profile><id>optional</id><build><plugins><plugin><artifactId>jacoco-maven-plugin</artifactId></plugin></plugins></build></profile></profiles></project>')
            child = root / 'child/pom.xml'
            child.parent.mkdir()
            child.write_text('<project><parent><groupId>demo</groupId><artifactId>parent</artifactId><version>1</version></parent></project>')
            self.assertEqual(signal.inherited_declaration(child), 'pom.xml')
            self.assertIsNone(signal.inherited_declaration(root / 'pom.xml'))


if __name__ == '__main__':
    unittest.main()
