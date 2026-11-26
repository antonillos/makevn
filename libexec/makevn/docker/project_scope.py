"""Select a stable Compose project name for an explicitly isolated checkout."""

import hashlib
import os
from pathlib import Path
import sys


def project_args(repo, compose):
    if os.environ.get("MAKEVN_COMPOSE_PROJECT_SCOPE") != "worktree":
        return []
    identity = f"{Path(repo).resolve()}\0{Path(compose).resolve()}"
    digest = hashlib.sha256(os.fsencode(identity)).hexdigest()[:20]
    return ["-p", f"makevn-{digest}"]


if __name__ == "__main__":
    for argument in project_args(*sys.argv[1:]):
        print(argument)
