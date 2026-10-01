import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('render_notes', ROOT / 'packaging/release/render-notes.py')
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ReleaseNotesTests(unittest.TestCase):
    def test_numeric_previous_stable_version(self):
        self.assertEqual(notes.previous_version('v0.1.13', ['v0.1.9', 'v0.1.12', 'v0.1.13', 'v0.1.14', 'v0.1.13-test.1']), 'v0.1.12')

    def test_initial_release_has_no_previous_version(self):
        self.assertIsNone(notes.previous_version('v0.1.0', ['v0.1.0', 'unrelated']))

    def test_prerelease_uses_previous_stable(self):
        self.assertEqual(notes.previous_version('v0.2.0-rc.1', ['v0.1.13', 'v0.2.0-rc.0']), 'v0.1.13')

    def test_highlights_and_changes_precede_installation(self):
        body = notes.render('v0.1.13', 'antonillos/makevn', '## What changed\n\nA real PR.', '## Highlights\n\nUser benefit.')
        self.assertLess(body.index('User benefit.'), body.index('A real PR.'))
        self.assertLess(body.index('A real PR.'), body.index('## Installation'))
        self.assertIn('/blob/main/docs/install.md', body)
        self.assertNotIn('brew install', body)

    def test_editorial_notes_collapse_technical_details(self):
        body = notes.render('v0.1.13', 'antonillos/makevn', 'Real PRs', 'Highlights', 'v0.1.12')
        self.assertIn('<details>', body)
        self.assertIn('/compare/v0.1.12...v0.1.13', body)

    def test_no_editorial_copy_still_has_changes(self):
        self.assertIn('Real changes', notes.render('v0.1.14', 'antonillos/makevn', 'Real changes'))

    def test_cli_generates_notes_with_explicit_previous_tag(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'notes.md'
            with patch('sys.argv', ['render-notes', 'v0.1.14', '--target', 'abc123', '--output', str(output)]), patch.object(notes, 'ROOT', Path(folder)), patch.object(notes.subprocess, 'check_output', side_effect=['v0.1.12\nv0.1.13\n', '{"body": "## Changes\\nReal PR"}']) as run:
                notes.main()
            command = run.call_args.args[0]
            self.assertIn('previous_tag_name=v0.1.13', command)
            self.assertIn('target_commitish=abc123', command)
            self.assertIn('Real PR', output.read_text())

    def test_empty_generated_changelog_stops_publication(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'notes.md'
            with patch('sys.argv', ['render-notes', 'v0.1.14', '--output', str(output)]), patch.object(notes.subprocess, 'check_output', side_effect=['v0.1.13\n', '{"body": ""}']):
                with self.assertRaises(RuntimeError):
                    notes.main()
            self.assertFalse(output.exists())

    def test_api_failure_does_not_create_notes(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'notes.md'
            with patch('sys.argv', ['render-notes', 'v0.1.14', '--output', str(output)]), patch.object(notes.subprocess, 'check_output', side_effect=['v0.1.13\n', notes.subprocess.CalledProcessError(1, 'gh')]):
                with self.assertRaises(notes.subprocess.CalledProcessError):
                    notes.main()
            self.assertFalse(output.exists())

    def test_invalid_version_is_rejected(self):
        with self.assertRaises(ValueError):
            notes.version_key('../unsafe')


if __name__ == '__main__':
    unittest.main()
