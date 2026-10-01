# Release notes presentation research

Reviewed on 2026-10-01. Star counts are approximate snapshots, not rankings.

| Project | Stars | Observed release presentation | Lesson for makevn |
| --- | ---: | --- | --- |
| [Zed](https://github.com/zed-industries/zed/releases) | 91k | Short editorial introduction, feature sections, bug fixes, linked PRs | Explain the user benefit before the implementation details |
| [GitHub CLI](https://github.com/cli/cli/releases) | 46k | Important notices first, categorized PR entries, contributors, full comparison | Keep changes traceable and distinguish maintenance from features |
| [uv](https://github.com/astral-sh/uv/releases) | 90k | Categorized release notes before version-specific installation and downloads | Installation must not obscure what changed |
| [Bun](https://github.com/oven-sh/bun/releases) | 96k | Installation/upgrade commands plus a prominent link to editorial blog notes | Marketing copy can be separate from the technical inventory |

## Decision

Use a Zed/GitHub CLI-inspired hybrid: concise reviewed benefit-oriented copy,
prominent migration notes, automatic linked technical changes, a visible version
comparison, and one canonical installation link. Collapse the technical inventory
when an editorial summary is present; keep it expanded otherwise. This last
layout choice is makevn's adaptation, not a claim that all four projects use it.

GitHub Releases remains the single changelog; version-specific highlight files
are editorial inputs, not a duplicate independently maintained changelog.
GitHub's [generated release notes](https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes)
provide PRs, contributors, and the comparison, not a trustworthy automatic
explanation of product value. Keep that distinction explicit.
