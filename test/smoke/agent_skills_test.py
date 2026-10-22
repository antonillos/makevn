"""Portable skill bundle, documentation links and public CLI examples."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NAMES = ('makevn', 'makevn-test', 'makevn-docker', 'makevn-karate', 'makevn-quality')


class SkillBundleTest(unittest.TestCase):
    def test_metadata_and_portable_links(self):
        self.assertEqual(sorted(p.name for p in (ROOT / 'skills').iterdir() if p.is_dir()), sorted(NAMES))
        for name in NAMES:
            skill = ROOT / 'skills' / name / 'SKILL.md'
            text = skill.read_text()
            self.assertTrue(text.startswith(f'---\nname: {name}\ndescription: >-\n'))
            self.assertLessEqual(len(text.split('---', 2)[1]), 1200)
            for path in skill.parent.rglob('*.md'):
                for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
                    if '://' not in target:
                        destination = (path.parent / target.split('#')[0]).resolve()
                        self.assertTrue(destination.is_relative_to(ROOT / 'skills'), (path, target))
                        self.assertTrue(destination.is_file(), (path, target))

    def test_cli_examples_use_known_commands(self):
        # Check every recipe's leading public command, including commands in tables.
        binary = ROOT / 'target/release/makevn'
        if not binary.exists():
            self.skipTest('Build release dispatcher before CLI contract checks')
        commands = set()
        for path in (ROOT / 'skills').rglob('*.md'):
            text = path.read_text()
            snippets = re.findall(r'(?<!`)`(makevn [^`\n]+)`(?!`)', text)
            snippets += re.findall(r'```bash\n(.*?)```', text, re.S)
            for snippet in snippets:
                commands.update(re.findall(r'(?:^|\n)makevn (?:--compact )?([a-z][a-z-]+)', snippet))
        # Natural-language mentions are not CLI examples.
        commands -= {'skill', 'product', 'version', 'command', 'tool', 'subcommands', 'commands'}
        for command in commands:
            result = subprocess.run([str(binary), command, '--help'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, (command, result.stderr))

    def test_cli_registration_both_clients_and_scopes(self):
        import os
        import shutil
        binary = ROOT / 'target/release/makevn'
        if not binary.exists():
            self.skipTest('Build release dispatcher first')
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            prefix = base / 'prefix'
            (prefix / 'bin').mkdir(parents=True)
            shutil.copy2(binary, prefix / 'bin/makevn')
            shutil.copytree(ROOT / 'skills', prefix / 'share/makevn/skills')
            home, repo = base / 'home', base / 'repo'
            home.mkdir()
            (repo / '.git').mkdir(parents=True)
            subdir = repo / 'module'
            subdir.mkdir()
            env = {**os.environ, 'HOME': str(home), 'CODEX_HOME': str(home / '.codex'), 'XDG_CONFIG_HOME': str(home / '.config'), 'MAKEVN_INSTALL_ROOT': str(prefix)}
            def run(action, client, scope):
                return subprocess.run([str(prefix / 'bin/makevn'), 'agent', action, client, '--scope', scope], cwd=subdir, env=env, capture_output=True, text=True)
            for scope in ('global', 'project'):
                for client in ('opencode', 'codex'):
                    before = sorted(str(p.relative_to(base)) for p in base.rglob('*'))
                    status = run('status', client, scope)
                    self.assertEqual(status.returncode, 0, status.stderr)
                    self.assertIn('absent', status.stdout)
                    self.assertEqual(before, sorted(str(p.relative_to(base)) for p in base.rglob('*')))
                    for _ in range(2):
                        result = run('install', client, scope)
                        self.assertEqual(result.returncode, 0, result.stderr)
                    status = run('status', client, scope)
                    self.assertIn('Skills status: current', status.stdout)
                    self.assertIn('MCP status: current', status.stdout)
            self.assertFalse((subdir / '.agents').exists())

    def test_release_archive_has_complete_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            import os
            import tarfile
            bin_dir = Path(tmp) / 'bin'
            bin_dir.mkdir()
            for name in ('makevn', 'makevn-mcp'):
                executable = bin_dir / name
                executable.write_text('#!/bin/sh\nexit 0\n')
                executable.chmod(0o755)
            subprocess.run(['bash', str(ROOT / 'packaging/release/build-runtime-archive.sh'), 'v0.0.0', 'skills-test', tmp], env={**os.environ, 'MAKEVN_BIN_DIR': str(bin_dir)}, check=True, capture_output=True)
            with tarfile.open(Path(tmp) / 'makevn-v0.0.0-skills-test.tar.gz') as archive:
                for name in NAMES:
                    for resource in (ROOT / 'skills' / name).rglob('*'):
                        if resource.is_file():
                            member = f'makevn-0.0.0-skills-test/share/makevn/skills/{resource.relative_to(ROOT / "skills")}'
                            self.assertEqual(archive.extractfile(member).read(), resource.read_bytes())


if __name__ == '__main__':
    unittest.main()
