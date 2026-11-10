"""Reactor planning and execution retain current checkout artifacts."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'libexec/makevn/common'))
from changes_scope import verification_plan


class ReactorVerificationTests(unittest.TestCase):
    def test_all_reactor_suites_do_not_require_resolving_profile_coordinates(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            repo.joinpath('pom.xml').write_text('<project><groupId>sample</groupId><artifactId>root</artifactId><version>1</version><packaging>pom</packaging><modules><module>a</module></modules></project>')
            repo.joinpath('a').mkdir()
            repo.joinpath('a/pom.xml').write_text('<project><groupId>sample</groupId><artifactId>a</artifactId><version>1</version><profiles><profile><id>default</id><activation><activeByDefault>true</activeByDefault></activation><properties><dependency.group>external</dependency.group></properties></profile></profiles><dependencies><dependency><groupId>${dependency.group}</groupId><artifactId>api</artifactId><version>1</version></dependency></dependencies></project>')
            resource = 'src/test/resources/shared/input.csv'
            repo.joinpath(resource).parent.mkdir(parents=True)
            repo.joinpath(resource).write_text('fixture')
            self.assertEqual(verification_plan(repo, repo, 'HEAD', [resource]), 'a\t*')

    def test_upstream_suites_are_visible_and_unrelated_modules_are_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            repo.joinpath('pom.xml').write_text('<project><groupId>sample</groupId><artifactId>root</artifactId><version>1</version><modules><module>api</module><module>consumer</module><module>other</module></modules></project>')
            for name in ('api', 'consumer', 'other'):
                repo.joinpath(name).mkdir()
                dependency = '<dependencies><dependency><groupId>sample</groupId><artifactId>api</artifactId><version>1</version></dependency></dependencies>' if name == 'consumer' else ''
                repo.joinpath(name, 'pom.xml').write_text('<project><groupId>sample</groupId><artifactId>' + name + '</artifactId><version>1</version>' + dependency + '</project>')
            test = repo / 'consumer/src/test/java/example/ConsumerTest.java'
            test.parent.mkdir(parents=True)
            test.write_text('class ConsumerTest {}')
            self.assertEqual(verification_plan(repo, repo, 'HEAD', [str(test.relative_to(repo))]), 'api\t*\nconsumer\t*')

    def test_execution_packages_then_verifies_same_reactor_and_propagates_failures(self):
        script = r'''
set -euo pipefail
SCRIPT_DIR="$1/libexec/makevn"
source "${SCRIPT_DIR}/commands/focused_changes.sh"
MAKEVN_VERIFY_CHANGES_MAVEN_BASE_PATH=/fixture
MAKEVN_VERIFY_CHANGES_MODULE_SELECTION=api,consumer
MAKEVN_VERIFY_CHANGES_FOCUSED_PLAN=$'api\t*\nconsumer\t*'
verify_args=(fake-maven)
cli_flags=()
prop_flags=()
makevn_state_dir() { printf /tmp; }
makevn_focused_coverage_gate_flags() { MAKEVN_FOCUSED_COVERAGE_GATE_FLAGS=(); }
makevn_focused_changes_phase() { printf '%s\n' "$*"; [[ "$*" != *'verify reactor suites'* ]] || return 42; }
makevn_scoped_coverage_checkpoint() { :; }
makevn_validate_prepared_impact() { :; }
makevn_run_focused_changes /fixture
'''
        result = subprocess.run(['bash', '-c', script, 'test', str(ROOT)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn('-pl api,consumer -am package -DskipTests=true', result.stdout)
        self.assertIn('-pl api,consumer -am verify -DskipTests=false', result.stdout)
        self.assertNotIn('install', result.stdout)
        self.assertNotIn('-Dtest=', result.stdout)


if __name__ == '__main__':
    unittest.main()
