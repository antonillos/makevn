#!/usr/bin/env python3
"""Find Compose files through directory links without changing their visible paths."""

import os
import sys


root, kind = sys.argv[1:]
seen_files = set()
pruned = {".git", ".makevn", "target"}
if kind == "boot":
    pruned |= {"e2e", "karate"}
    starts = [root]
else:
    starts = [os.path.join(root, name) for name in ("e2e", "karate")]


def walk(path, ancestors):
    if not os.path.exists(path):
        if os.path.islink(path):
            print(f"Broken Compose directory link: {path}", file=sys.stderr)
        return
    canonical = os.path.realpath(path)
    if canonical in ancestors:
        return
    try:
        entries = sorted(os.scandir(path), key=lambda entry: entry.name)
    except OSError as error:
        print(f"Cannot inspect Compose directory {path}: {error}", file=sys.stderr)
        return
    for entry in entries:
        if entry.name in pruned:
            continue
        if entry.is_dir(follow_symlinks=True):
            walk(entry.path, ancestors | {canonical})
        elif entry.name == "docker-compose.yml" and entry.is_file(follow_symlinks=True):
            resolved = os.path.realpath(entry.path)
            if resolved not in seen_files:
                seen_files.add(resolved)
                print(entry.path)
        elif entry.is_symlink() and not os.path.exists(entry.path):
            print(f"Broken Compose link: {entry.path}", file=sys.stderr)


for start in starts:
    walk(start, set())
