"""Docker listing scope and failures without a Compose prerequisite."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DockerPsScopeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        docker = self.directory / 'docker'
        docker.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
case "$1" in
  ps) [[ "$LIST_RC" == 0 ]] || { echo 'engine unavailable' >&2; exit "$LIST_RC"; }; printf '%s' "$IDS" ;;
  compose) printf 'compose-id\\n' ;;
  inspect)
    case "$3" in
      '{{.Name}}') printf '/fixture-container\\n' ;;
      '{{.State.Status}}') printf 'exited\\n' ;;
      *) printf 'none\\n' ;;
    esac ;;
  *) exit 91 ;;
esac
''')
        docker.chmod(0o755)
        self.environment = {**os.environ, 'PATH': str(self.directory) + ':/usr/bin:/bin',
                            'CALLS': str(self.directory / 'calls'), 'LIST_RC': '0', 'IDS': '',
                            'MAKEVN_EXECUTION_COMPOSE_FILE': 'none', 'COMPOSE_ARGS': '',
                            'SERVICES': '', 'DOCKER_COMPOSE': 'docker compose',
                            'SHOW_ALL_CONTAINERS': 'false'}

    def run_listing(self, **overrides):
        return subprocess.run(['bash', str(ROOT / 'libexec/makevn/docker/ps.sh')],
                              env={**self.environment, **overrides}, text=True, capture_output=True)

    def test_explicit_none_lists_engine_without_compose_or_stale_services(self):
        result = self.run_listing(IDS='engine-id\n', SERVICES='old-service', COMPOSE_ARGS='-f stale.yml')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scope: Docker engine', result.stdout)
        self.assertIn('repository ownership and readiness not established', result.stdout)
        self.assertIn('fixture-container', result.stdout)
        self.assertIn('exited', result.stdout)
        calls = (self.directory / 'calls').read_text()
        self.assertIn('ps -aq', calls)
        self.assertNotIn('compose', calls)

    def test_empty_engine_succeeds_and_engine_failure_keeps_its_status(self):
        result = self.run_listing()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scope: Docker engine', result.stdout)
        failed = self.run_listing(LIST_RC='17')
        self.assertEqual(failed.returncode, 17)
        self.assertIn('engine unavailable', failed.stderr)
        self.assertNotIn('NAME', failed.stdout)

    def test_no_compose_override_keeps_existing_engine_listing(self):
        result = self.run_listing(MAKEVN_EXECUTION_COMPOSE_FILE='')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scope: Docker engine', result.stdout)
        self.assertEqual((self.directory / 'calls').read_text(), 'ps -aq\n')

    def test_explicit_compose_file_retains_compose_scope(self):
        result = self.run_listing(MAKEVN_EXECUTION_COMPOSE_FILE=str(self.directory / 'custom compose.yml'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('Scope: Docker engine', result.stdout)
        calls = (self.directory / 'calls').read_text()
        self.assertIn('compose -f ', calls)
        self.assertIn('custom compose.yml ps -aq', calls)
        self.assertNotIn('\nps -aq', '\n' + calls)


if __name__ == '__main__':
    unittest.main()
