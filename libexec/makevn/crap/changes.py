#!/usr/bin/env python3
"""Changed production Java line ranges relative to a Git merge base."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, stdout=subprocess.PIPE).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    repo = Path(args.repo_root).resolve()
    try:
        base = git(repo, "merge-base", args.base, "HEAD").decode().strip()
        diff = git(repo, "diff", "--no-ext-diff", "--no-color", "--unified=0", "--no-renames", base, "--", "*.java").decode("utf-8", "replace")
        untracked = git(repo, "ls-files", "--others", "--exclude-standard", "-z", "--", "*.java").decode().split("\0")
    except subprocess.CalledProcessError as exc:
        print(f"Error: cannot compare Java changes with base {args.base}: {exc}", file=sys.stderr)
        return 2
    changed = {}
    path = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
        elif line == "+++ /dev/null":
            path = None
        elif path and line.startswith("@@ "):
            match = re.search(r"\+(\d+)(?:,(\d+))? @@", line)
            if match:
                start = int(match[1])
                count = int(match[2] or 1)
                # A deletion-only edit still changes its containing method.
                end = start + max(count, 1) - 1
                changed.setdefault(path, []).append([max(start, 1), max(end, 1)])
    for path in filter(None, untracked):
        source = repo / path
        if source.is_file():
            changed[path] = [[1, max(len(source.read_text(errors="replace").splitlines()), 1)]]
    changed = {path: ranges for path, ranges in changed.items() if "/src/main/java/" in f"/{path}"}
    Path(args.output).write_text(json.dumps({"base": args.base, "merge_base": base, "files": changed}, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
