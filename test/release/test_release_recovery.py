"""Execute the release workflow's shell steps against a fake GitHub CLI."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text()


def step_script(name):
    step = WORKFLOW.split(f"- name: {name}\n", 1)[1]
    step = re.split(r"\n      - name:|\n  [a-z]", step, maxsplit=1)[0]
    script = step.split("        run: |\n", 1)[1]
    script = "\n".join(line[10:] for line in script.splitlines())
    return re.sub(r"\$\{\{ (.*?) \}\}", lambda match: {
        "needs.validate-version.outputs.version": "v1.2.3",
        "needs.validate-version.outputs.target-ref": "abc123",
        "needs.validate-version.outputs.prerelease": "false",
    }[match[1]], script)


class ReleaseRecoveryTests(unittest.TestCase):
    def run_step(self, name, assets="", exists=True, draft=False, fail_create=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / "gh"
            gh.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$CALLS"
case "$1 $2" in
  'release view')
    [[ "$EXISTS" == true ]] || exit 1
    if [[ "$*" == *--json* ]]; then
      if [[ "$DRAFT" == true ]]; then printf 'DRAFT\\n'; else cat "$ASSETS"; fi
    fi
    ;;
  'release create') [[ "$FAIL_CREATE" == false ]] ;;
  *) exit 2 ;;
esac
''')
            gh.chmod(0o755)
            (root / "assets").write_text(assets)
            output = root / "output"
            output.touch()
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       CALLS=str(root / "calls"), ASSETS=str(root / "assets"),
                       GITHUB_OUTPUT=str(output), VERSION="v1.2.3",
                       EXISTS=str(exists).lower(), DRAFT=str(draft).lower(),
                       FAIL_CREATE=str(fail_create).lower())
            result = subprocess.run(["bash", "-c", step_script(name)],
                                    cwd=root, env=env, capture_output=True, text=True)
            return result, output.read_text(), (root / "calls").read_text()

    def all_assets(self):
        return "\n".join(f"makevn-v1.2.3{suffix}{extension}" for suffix in
                         ("", "-x86_64-unknown-linux-gnu", "-x86_64-apple-darwin",
                          "-aarch64-apple-darwin")
                         for extension in (".tar.gz", ".tar.gz.sha256")) + "\n"

    def test_missing_release_requires_uploads(self):
        result, output, _ = self.run_step("Check release completeness", exists=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "exists=false\n")

    def test_each_missing_asset_requires_uploads(self):
        assets = self.all_assets().splitlines()
        for missing in assets:
            with self.subTest(missing=missing):
                result, output, _ = self.run_step("Check release completeness",
                                                 "\n".join(a for a in assets if a != missing))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, "exists=false\n")

    def test_complete_published_release_is_skipped(self):
        result, output, _ = self.run_step("Check release completeness", self.all_assets())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "exists=true\n")

    def test_complete_draft_can_resume_finalization(self):
        result, output, _ = self.run_step("Check release completeness", self.all_assets(), draft=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "exists=false\n")

    def test_existing_partial_release_is_preserved(self):
        result, _, calls = self.run_step("Create GitHub release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("release create", calls)
        self.assertNotIn("release delete", calls)

    def test_new_release_starts_as_draft(self):
        result, _, calls = self.run_step("Create GitHub release", exists=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release create v1.2.3", calls)
        self.assertIn("--draft", calls)

    def test_create_failure_propagates(self):
        result, _, _ = self.run_step("Create GitHub release", exists=False, fail_create=True)
        self.assertNotEqual(result.returncode, 0)

    def test_failed_uploads_block_publication(self):
        finalize = WORKFLOW.split("  finalize-release:\n", 1)[1]
        self.assertIn("needs: [validate-version, build-runtime-archives, build-source-archive]", finalize)
        self.assertNotIn("always()", finalize)
        self.assertIn("needs.validate-version.outputs.draft != 'true'", finalize)
        self.assertIn('gh release edit "$VERSION" --draft=false', finalize)


if __name__ == "__main__":
    unittest.main()
