"""Prove no-code exclusions using real bytecode, not source-name guesses."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

report = module('crap_report', ROOT / 'libexec/makevn/crap/report.py')
scoped = module('scoped_coverage', ROOT / 'libexec/makevn/common/scoped_coverage.py')

@unittest.skipUnless(shutil.which('javac') and shutil.which('javap'), 'JDK required')
class NonExecutableTests(unittest.TestCase):
    def test_interfaces_default_methods_nested_code_and_stale_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '--allow-empty', '-qm', 'base'], check=True)
            source = repo / 'code/domain/src/main/java/example'
            target = repo / 'code/domain/target/classes'
            source.mkdir(parents=True)
            target.mkdir(parents=True)
            declarations = {
                'Repository': 'public interface Repository { void save(); }',
                'DefaultRepository': 'public interface DefaultRepository { default int size() { return 1; } }',
                'NestedRepository': 'public interface NestedRepository { class Impl { int size() { return 1; } } }',
                'MultipleRepository': 'public interface MultipleRepository {} class Helper { int size() { return 1; } }',
            }
            paths = []
            for name, declaration in declarations.items():
                path = source / (name + '.java')
                path.write_text('package example; ' + declaration)
                paths.append(path.relative_to(repo).as_posix())
            subprocess.run(['javac', '-d', str(target), *[str(repo / path) for path in paths]], check=True)
            state = repo / '.makevn/focused-coverage'
            scoped.prepare(repo, state, repo / 'code', ['domain'], paths)
            (target.parent / 'jacoco.exec').write_bytes(b'fresh data')
            scoped.finish(repo, state)
            ignored = report.non_executable_sources(paths, repo, str(state), shutil.which('javap'))
            self.assertEqual(ignored, {paths[0]})
            raw = repo / 'analyzer.json'
            raw.write_text('{"entries": []}')
            changes = repo / 'changes.json'
            changes.write_text(json.dumps({'base': 'HEAD', 'merge_base': 'HEAD', 'files': {paths[0]: [[1, 1]]}}))
            output = repo / '.makevn/report'
            command = ['python3', str(ROOT / 'libexec/makevn/crap/report.py'), '--input', str(raw),
                       '--output-dir', str(output), '--changes-file', str(changes), '--repo-root', str(repo),
                       '--source-root', str(repo), '--focused-state', str(state), '--javap', shutil.which('javap')]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((output / 'report.json').read_text())['diagnostics']['non_executable_sources'], [paths[0]])
            changes.write_text(json.dumps({'base': 'HEAD', 'merge_base': 'HEAD', 'files': {paths[1]: [[1, 1]]}}))
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn(paths[1], result.stderr)
            changes.write_text(json.dumps({'base': 'HEAD', 'merge_base': 'HEAD', 'files': {paths[3]: [[1, 1]]}}))
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn(paths[3], result.stderr)
            self.assertEqual(report.non_executable_sources(paths, repo, None, None), set())
            with self.assertRaises((OSError, subprocess.CalledProcessError)):
                report.non_executable_sources(paths, repo, str(state), '/missing/javap')
            (repo / paths[0]).write_text('changed source')
            with self.assertRaisesRegex(ValueError, 'sources/config changed'):
                report.non_executable_sources(paths, repo, str(state), shutil.which('javap'))

class AssociationTests(unittest.TestCase):
    def test_conservative_top_level_association(self):
        self.assertTrue(report.single_top_level_type('/* class Fake {} */ interface Owner { String TEXT = "class Fake {}"; }'))
        self.assertFalse(report.single_top_level_type('interface Owner {} class Helper {}'))
        self.assertFalse(report.single_top_level_type(r'interface Owner {} \u0063lass Helper {}'))

if __name__ == '__main__':
    unittest.main()
