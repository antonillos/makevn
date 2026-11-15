import importlib.util
from pathlib import Path
import tempfile
import unittest

path = Path(__file__).resolve().parents[2] / 'libexec/makevn/common/jacoco_effective.py'
spec = importlib.util.spec_from_file_location('jacoco_effective', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class EffectiveModelTests(unittest.TestCase):
    def inspect(self, plugin, properties='', user_skip='false'):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / 'model.xml'
            model.write_text(f'<project><artifactId>sample</artifactId><properties>{properties}</properties><build>{plugin}</build></project>')
            return module.classify(model, user_skip)[0]['status']

    def test_active_inactive_and_unresolved_bindings(self):
        template = '<plugins><plugin><groupId>org.jacoco</groupId><artifactId>jacoco-maven-plugin</artifactId><executions><execution>{}<goals><goal>prepare-agent</goal></goals></execution></executions></plugin></plugins>'
        self.assertEqual(self.inspect(template.format('')), 'configured')
        self.assertEqual(self.inspect(template.format(''), user_skip='true'), 'absent')
        self.assertEqual(self.inspect(template.format(''), user_skip=None), 'unknown')
        self.assertEqual(self.inspect(template.format(''), '<jacoco.skip>false</jacoco.skip>', user_skip=None), 'unknown')
        self.assertEqual(self.inspect(template.format('<configuration><skip>true</skip></configuration>'), user_skip='true'), 'absent')
        self.assertEqual(self.inspect(template.format('<configuration><skip>false</skip></configuration>'), user_skip='true'), 'unknown')
        self.assertEqual(self.inspect(template.format('').replace('org.jacoco', 'other.vendor')), 'unknown')
        self.assertEqual(self.inspect(template.format('').replace('prepare-agent', 'prepare-agent-integration')), 'unknown')
        self.assertEqual(self.inspect(template.format('<phase>none</phase>')), 'absent')
        self.assertEqual(self.inspect(template.format('<phase>verify</phase>')), 'unknown')
        self.assertEqual(self.inspect(template.format('<configuration><skip>${jacoco.skip}</skip></configuration>'), '<jacoco.skip>true</jacoco.skip>'), 'configured')
        self.assertEqual(self.inspect(template.format('<configuration><skip>true</skip></configuration>')), 'unknown')
        self.assertEqual(self.inspect(template.format('<configuration><skip>${unknown}</skip></configuration>')), 'unknown')
        self.assertEqual(self.inspect(template.format('<configuration><skip>${flag}</skip></configuration>'), '<flag>false</flag>'), 'unknown')
        self.assertEqual(self.inspect('<pluginManagement>' + template.format('') + '</pluginManagement>'), 'absent')

    def test_reactor_and_invalid_model(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / 'model.xml'
            model.write_text('<projects><project><artifactId>a</artifactId></project><project><artifactId>b</artifactId></project></projects>')
            self.assertEqual([p['status'] for p in module.classify(model)], ['absent', 'absent'])
            model.write_text('<invalid/>')
            with self.assertRaises(ValueError):
                module.classify(model)


if __name__ == '__main__':
    unittest.main()
