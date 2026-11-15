"""Offline base selection and CLI scope regressions."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec/makevn/common'))
from changes_base import detect, resolve


class BaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git('init', '-q', '--initial-branch=main')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.test')
        self.git('config', 'commit.gpgsign', 'false')
        (self.repo / 'pom.xml').write_text('<project/>')
        self.git('add', '.')
        self.git('commit', '-qm', 'root')
        self.root = self.git('rev-parse', 'HEAD')
        self.tree = self.git('rev-parse', 'HEAD^{tree}')
        self.sequence = 0

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL).decode().strip()

    def commit(self, *parents):
        self.sequence += 1
        args = ['commit-tree', self.tree, '-m', 'commit ' + str(self.sequence)]
        for parent in parents:
            args += ['-p', parent]
        return self.git(*args)

    def ambiguous_graph(self):
        spine = self.commit(self.root)
        main = self.commit(self.root)
        develop = self.commit(self.root)
        head = self.commit(self.commit(spine, main, develop))
        self.git('update-ref', 'refs/heads/main', self.commit(main))
        self.git('update-ref', 'refs/heads/develop', self.commit(develop))
        self.git('checkout', '-q', '--detach', head)
        return main, develop, head

    def test_equal_rank_different_merge_bases_require_explicit_destination(self):
        self.ambiguous_graph()
        with self.assertRaisesRegex(ValueError, 'Ambiguous.*main, develop.*--base'):
            detect(self.repo)
        self.assertEqual(resolve(self.repo, 'develop')[1], self.git('merge-base', 'develop', 'HEAD'))

    def test_aliases_and_advanced_tips_with_same_merge_base_are_not_ambiguous(self):
        self.git('update-ref', 'refs/remotes/origin/main', self.root)
        self.git('branch', 'develop', self.root)
        self.git('checkout', '-qb', 'feature')
        self.git('commit', '--allow-empty', '-qm', 'feature')
        self.assertEqual(detect(self.repo), 'origin/main...HEAD')
        self.git('update-ref', 'refs/heads/main', self.commit(self.root))
        self.git('update-ref', 'refs/heads/develop', self.commit(self.root))
        self.git('update-ref', 'refs/remotes/origin/main', self.commit(self.root))
        self.assertEqual(detect(self.repo), 'origin/main...HEAD')

    def test_invalid_ranges_missing_refs_and_noncommit_objects_fail(self):
        blob = self.git('hash-object', 'pom.xml')
        for ref in ['missing', '', '--help', 'main...HEAD', 'main..HEAD', blob]:
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                resolve(self.repo, ref)

    def test_unrelated_history_and_multiple_merge_bases_fail(self):
        unrelated = self.commit()
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            resolve(self.repo, unrelated)
        a, b = self.commit(self.root), self.commit(self.root)
        left, right = self.commit(a, b), self.commit(b, a)
        self.git('checkout', '-q', '--detach', left)
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            resolve(self.repo, right)

    def test_shallow_clone_missing_base_fails_without_fetching(self):
        self.git('commit', '--allow-empty', '-qm', 'tip')
        shallow = self.repo / 'shallow'
        subprocess.run(['git', 'clone', '-q', '--depth=1', self.repo.as_uri(), str(shallow)], check=True)
        with self.assertRaisesRegex(ValueError, 'unavailable'):
            resolve(shallow, self.root)
        self.assertEqual(subprocess.check_output(['git', '-C', str(shallow), 'rev-list', '--count', 'HEAD']).strip(), b'1')

    def test_hotfix_and_release_ancestry_remain_unambiguous(self):
        self.git('branch', 'develop', self.commit(self.root))
        self.git('checkout', '-qb', 'hotfix')
        self.git('commit', '--allow-empty', '-qm', 'fix')
        self.assertEqual(detect(self.repo), 'main...HEAD')
        release = self.commit(self.root)
        self.git('branch', 'release/next', release)
        self.git('checkout', '-q', '--detach', self.commit(release))
        self.assertEqual(detect(self.repo), 'release/next...HEAD')

    def test_explicit_base_works_in_a_linked_detached_worktree(self):
        self.ambiguous_graph()
        self.git('update-ref', 'refs/remotes/origin/develop', self.git('rev-parse', 'develop'))
        worktree = self.repo / 'review'
        self.git('worktree', 'add', '-q', '--detach', str(worktree), 'HEAD')
        subprocess.run([str(ROOT / 'bin/makevn'), '--repo', str(worktree), 'init'], check=True, capture_output=True)
        result = subprocess.run([str(ROOT / 'bin/makevn'), '--repo', str(worktree), 'verify-changes-preview',
                                 '--base', 'origin/develop', '--exhaustive'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('compare against: origin/develop...HEAD', result.stdout)
        self.assertIn('base source: explicit', result.stdout)
        self.assertEqual(subprocess.run(['git', '-C', str(worktree), 'symbolic-ref', '-q', 'HEAD']).returncode, 1)

    def test_explicit_base_controls_preview_and_execution_in_detached_and_attached_worktrees(self):
        _, develop, _ = self.ambiguous_graph()
        self.git('update-ref', 'refs/remotes/origin/develop', self.git('rev-parse', 'develop'))
        script = r'''
set -euo pipefail
SCRIPT_DIR="$1/libexec/makevn"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/commands/changes.sh"
makevn_load_profile() { :; }
makevn_detect_maven_base_path() { printf '%s' "$1"; }
makevn_maven_executable() { printf unused; }
makevn_effective_local_containers() { :; }
makevn_refresh_impact() { :; }
makevn_frontend_owns_loader() { return 0; }
makevn_write_verify_changes_plan() { :; }
makevn_print_changes_coverage_signal() { :; }
cmd_verify() { printf 'verified base=%s\n' "${MAKEVN_VERIFY_CHANGES_PARENT_SPEC}"; }
"$3" "$2" --exhaustive --base origin/develop
'''
        source = self.repo / 'src/main/java/Local.java'
        source.parent.mkdir(parents=True)
        source.write_text('class Local {}')
        self.git('add', str(source))
        for attached in [False, True]:
            if attached:
                self.git('checkout', '-q', 'develop')
            for command in ['cmd_verify_changes_preview', 'cmd_verify_changes']:
                with self.subTest(attached=attached, command=command):
                    result = subprocess.run(['bash', '-c', script, 'test', str(ROOT), str(self.repo), command], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('compare against: origin/develop...HEAD', result.stdout)
                    self.assertIn('base source: explicit', result.stdout)
                    self.assertIn('comparison merge base: ' + (self.git('rev-parse', 'develop') if attached else develop), result.stdout)
                    self.assertIn('production files: 1', result.stdout)


if __name__ == '__main__':
    unittest.main()
