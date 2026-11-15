"""Exercise version bumps in an isolated checkout with real Homebrew formulas."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BumpVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "makevn"
        (self.repo / "rust/dispatcher").mkdir(parents=True)
        self.manifest = self.repo / "rust/dispatcher/Cargo.toml"
        self.manifest.write_text('[package]\nname = "makevn-dispatcher"\nversion = "0.5.0"\n')
        shutil.copy2(ROOT / "bump-version.sh", self.repo / "bump-version.sh")
        self.formulas = [self.repo / "packaging/homebrew/makevn.rb",
                         self.root / "homebrew-tap/Formula/makevn.rb"]
        for formula in self.formulas:
            formula.parent.mkdir(parents=True)
            shutil.copy2(ROOT / "packaging/homebrew/makevn.rb", formula)
        self.original_formulas = [formula.read_bytes() for formula in self.formulas]

    def bump(self, version):
        return subprocess.run(["bash", str(self.repo / "bump-version.sh"), version],
                              cwd=self.root, env=os.environ.copy(),
                              capture_output=True, text=True)

    def test_stable_and_prerelease_bumps_preserve_formulas(self):
        for version in ("0.6.0", "0.7.0-dev.1"):
            with self.subTest(version=version):
                result = self.bump(version)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'version = "{version}"', self.manifest.read_text())
                self.assertEqual([f.read_bytes() for f in self.formulas], self.original_formulas)
                self.assertIn("release workflow updates Homebrew", result.stdout)

    def test_invalid_version_changes_nothing(self):
        original = self.manifest.read_bytes()
        result = self.bump("invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.manifest.read_bytes(), original)
        self.assertEqual([f.read_bytes() for f in self.formulas], self.original_formulas)


if __name__ == "__main__":
    unittest.main()
