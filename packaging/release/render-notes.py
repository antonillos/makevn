#!/usr/bin/env python3
"""Render release notes from GitHub's generated changes and optional editorial copy."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"v(\d+)\.(\d+)\.(\d+)(?:-[A-Za-z0-9.]+)?")


def version_key(tag):
    match = VERSION.fullmatch(tag)
    if not match:
        raise ValueError(f"Invalid release version: {tag}")
    return tuple(map(int, match.groups()))


def previous_version(version, tags):
    key = version_key(version)
    stable = [tag for tag in tags if VERSION.fullmatch(tag) and "-" not in tag
              and version_key(tag) < key]
    return max(stable, key=version_key) if stable else None


def render(version, repository, changes, highlights="", previous=None):
    version_key(version)
    base = f"https://github.com/{repository}"
    sections = [f"# makevn {version}"]
    if highlights.strip():
        sections.append(highlights.strip())
    details = changes.strip() or "## Changes\n\nNo pull-request entries were generated. See the tagged source for this release."
    if highlights.strip():
        details = "<details>\n<summary>Full changelog and contributors</summary>\n\n" + details + "\n\n</details>"
    sections.append(details)
    if previous:
        version_key(previous)
        sections.append(f"[Compare {previous} → {version}]({base}/compare/{previous}...{version})")
    sections.append(f"## Installation\n\n[Install or upgrade makevn]({base}/blob/main/docs/install.md) "
                    "— Homebrew, asdf, release installer, and MCP setup.")
    sections.append("## Assets\n\n- Runtime archives: Linux x86_64, macOS x86_64, and macOS arm64\n"
                    "- Source archive\n- SHA-256 checksums for each archive")
    sections.append(f"[All releases / changelog]({base}/releases)")
    return "\n\n".join(sections) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--repository", default="antonillos/makevn")
    parser.add_argument("--target", default="main")
    parser.add_argument("--previous")
    parser.add_argument("--changes", type=Path, help="Offline generated-notes body")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version_key(args.version)
    tags = subprocess.check_output(["git", "tag", "--list"], cwd=ROOT, text=True).splitlines()
    previous = args.previous or previous_version(args.version, tags)
    if args.changes:
        changes = args.changes.read_text()
    else:
        command = ["gh", "api", f"repos/{args.repository}/releases/generate-notes",
                   "-f", f"tag_name={args.version}", "-f", f"target_commitish={args.target}"]
        if previous:
            command += ["-f", f"previous_tag_name={previous}"]
        changes = json.loads(subprocess.check_output(command, cwd=ROOT, text=True))["body"]
        if not changes.strip():
            raise RuntimeError("GitHub generated an empty changelog; refusing installation-only notes")
    highlights = ROOT / "docs" / "release-highlights" / f"{args.version}.md"
    args.output.write_text(render(args.version, args.repository, changes,
                                  highlights.read_text() if highlights.exists() else "", previous))


if __name__ == "__main__":
    main()
