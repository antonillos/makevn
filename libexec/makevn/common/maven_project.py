#!/usr/bin/env python3
"""Find an unambiguous outer Maven project without selecting a reactor child."""
import os
from pathlib import Path
import sys


def discover(root):
    root = Path(root)
    for preferred in (root, root / "code"):
        if (preferred / "pom.xml").is_file():
            return preferred
    candidates = []
    for directory, children, files in os.walk(root):
        children[:] = sorted(name for name in children
                             if name not in {".git", ".makevn", "target", "node_modules"})
        if "pom.xml" in files:
            candidates.append(Path(directory))
            children.clear()
    if len(candidates) > 1:
        names = ", ".join(str(path.relative_to(root)) for path in candidates)
        raise ValueError("Ambiguous Maven projects: " + names +
                         ". Use an isolated checkout containing the intended Maven project.")
    return candidates[0] if candidates else None


def main(args):
    try:
        selected = discover(args[0])
        if selected is None:
            return 1
        print(selected)
        return 0
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
