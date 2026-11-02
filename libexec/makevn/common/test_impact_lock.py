"""Hold an advisory checkout capture lock across the backend process tree."""
import fcntl
import os
from pathlib import Path
import sys

repo, script, *arguments = sys.argv[1:]
directory = Path(repo) / '.makevn/test-impact'
directory.mkdir(parents=True, exist_ok=True)
lock = os.open(directory / 'capture.lock', os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit('Test impact capture is already running in this checkout')
os.set_inheritable(lock, True)
os.environ['MAKEVN_TEST_IMPACT_LOCK_HELD'] = 'true'
os.execvp('bash', ['bash', script, '--repo', repo, *arguments])
