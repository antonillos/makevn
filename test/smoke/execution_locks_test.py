"""Terminal metadata alone does not establish that execution locks are released."""
import fcntl
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('execution_mcp_test', Path(__file__).with_name('execution_mcp_test.py'))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


class ExecutionLocksTests(unittest.TestCase):
    def test_waits_for_lifetime_and_matching_resource_locks_only(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            registry = state / 'makevn/executions'
            resource = registry / 'locks/repository.lock'
            resource.parent.mkdir(parents=True)
            lifetime = registry / 'owned/lifetime.lock'
            lifetime.parent.mkdir()
            lifetime.touch()
            resource.write_text(json.dumps({'executionId': 'owned'}))
            foreign = registry / 'locks/foreign.lock'
            foreign.write_text(json.dumps({'executionId': 'other'}))
            with lifetime.open('r') as active, resource.open('r') as held, foreign.open('r') as other:
                fcntl.flock(active, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertFalse(lifecycle.execution_locks_released(state, 'owned'))
                fcntl.flock(active, fcntl.LOCK_UN)
                self.assertFalse(lifecycle.execution_locks_released(state, 'owned'))
                fcntl.flock(held, fcntl.LOCK_UN)
                self.assertTrue(lifecycle.execution_locks_released(state, 'owned'))


if __name__ == '__main__':
    unittest.main()
