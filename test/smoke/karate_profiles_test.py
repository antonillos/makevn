"""Profile detection must never evaluate workflow expressions or shell code."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('karate_profiles', ROOT / 'libexec/makevn/common/karate_profiles.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProfilesTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.repo = Path(self.folder.name)
        self.workflows = self.repo / '.github/workflows'
        self.workflows.mkdir(parents=True)

    def workflow(self, name, text):
        (self.workflows / name).write_text(text)

    def test_literal_arguments_and_environment_are_equivalent(self):
        self.workflow('karate.yml', 'run: java -jar app.jar --spring.profiles.active=standalone,local\n')
        self.workflow('e2e.yaml', 'name: Karate\nenv:\n  SPRING_PROFILES_ACTIVE: "standalone,local"\n')
        result = module.detect(self.repo)
        self.assertEqual(result['profiles'], 'standalone,local')
        self.assertEqual(result['status'], 'resolved')
        self.assertIn('karate.yml:1', result['source'])
        self.assertIn('e2e.yaml:3', result['source'])

    def test_missing_and_unrelated_workflows_do_not_guess(self):
        self.workflow('unit.yml', 'env:\n  SPRING_PROFILES_ACTIVE: unit\n')
        result = module.detect(self.repo)
        self.assertEqual(result['status'], 'missing')
        self.assertEqual(result['profiles'], '')

    def test_conflicting_workflows_are_not_selected(self):
        self.workflow('karate.yml', 'SPRING_PROFILES_ACTIVE: local\n')
        self.workflow('karate-other.yml', '--spring.profiles.active=standalone\n')
        result = module.detect(self.repo)
        self.assertEqual(result['status'], 'ambiguous')
        self.assertEqual(result['profiles'], '')
        self.assertIn('standalone', result['candidates'])

    def test_dynamic_values_prevent_automatic_selection(self):
        for value in ['${{ vars.PROFILES }}', '${PROFILES}', '$(touch /tmp/unsafe)', '[local, standalone]']:
            with self.subTest(value=value):
                self.workflow('karate.yml', f'SPRING_PROFILES_ACTIVE: "{value}"\n--spring.profiles.active=local\n')
                result = module.detect(self.repo)
                self.assertEqual(result['status'], 'ambiguous')
                self.assertEqual(result['profiles'], '')
                self.assertIn('dynamic/unrecognized', result['candidates'])

    def test_comments_are_not_configuration(self):
        self.workflow('karate.yml', '# SPRING_PROFILES_ACTIVE: fake\nSPRING_PROFILES_ACTIVE=local # comment\n')
        self.assertEqual(module.detect(self.repo)['profiles'], 'local')


if __name__ == '__main__':
    unittest.main()
