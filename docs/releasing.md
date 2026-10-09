# Release Process

## Version source

The canonical version is the `version` field in
`rust/dispatcher/Cargo.toml`. Release tags use the same version prefixed with
`v`.

## Standard release

1. Ensure the intended changes have reached `develop`, run **Prepare Promotion**,
   and merge the generated `develop` → `main` PR through the protected PR process
   using a merge commit. The workflow reuses an existing promotion PR and does
   nothing when there are no commits to promote; it never merges, changes the
   version, or publishes a release.
2. Run **Prepare Release** and select the semantic-version increment, or provide
   an exact version when required.
3. Review and merge the generated release PR after all required checks pass.
4. Confirm that the release assets and supported package-manager channels were
   published successfully.
5. Confirm that the post-release branch synchronization completed.

The automation validates the version, builds and tests the distributable
artifacts, creates the GitHub release, publishes checksums, and updates the
supported package-manager repositories. Do not create tags or update downstream
repositories manually during the normal path.

## Recovery

The release and package-manager workflows support authorized manual dispatches
for recovery. Reuse the exact version and target revision from the failed run,
and inspect the existing release state before retrying. Avoid deleting or
replacing a successful release unless rollback has been explicitly approved.

## Prerelease validation

Use **Release Test** with a unique prerelease version when validating packaging
changes. Test releases must not be treated as stable package-manager releases.

## Runtime archive contract

Each runtime archive contains:

```text
bin/makevn
bin/makevn-mcp
libexec/makevn/
share/makevn/
share/makevn/skills/makevn/
```

Homebrew, asdf, and the fallback installer consume the same runtime layout.

## Security boundary

Release operations use the repository's dedicated automation identity and
protected settings. Keep credential values, exact permission mappings, and
recovery internals out of documentation, logs, issues, and pull-request text.
Changes to release authorization must be reviewed separately from ordinary
packaging changes.

## Release notes and changelog

[GitHub Releases](https://github.com/antonillos/makevn/releases) is the canonical
changelog, linked from the README. The release workflow generates PR entries,
contributors, and a comparison against the previous stable version through the
GitHub release-notes API. `.github/release.yml` groups labelled PRs; unlabelled
changes remain visible under Other changes. Label feature PRs `enhancement`,
fixes `bug`, documentation `documentation`, and dependency updates `dependencies`.

For an editorial introduction, include `docs/release-highlights/vX.Y.Z.md` in
the revision being released, before merging the release PR. Use a short,
benefit-oriented introduction and 3–5 concrete highlights. Put breaking changes
and migration instructions before highlights. Explain maintenance honestly;
do not turn a dependency bump into a product feature or claim unmeasured speedups.
This optional introduction is reviewed copy, not AI-generated marketing in CI.
Without it, generated changes are still published automatically.

`packaging/release/render-notes.py` assembles the introduction, a collapsible
technical changelog when editorial copy exists, a visible compare link, the
canonical installation guide, and asset information. Generation failures stop
publication rather than silently shipping installation-only notes.

The historical introductions for v0.1.0–v0.1.13 were reconstructed from tagged
commit ranges and source diffs, including squash-merged promotions. GitHub's
PR-only generator can miss feature detail hidden inside a promotion PR, and
branch synchronization can repeat older commits: inspect source deltas before
attributing a feature to a release. Only release descriptions are changed during
backfill; preserve tags, assets, publication dates, and release status. Back up
existing descriptions before editing and compare the saved metadata afterwards.

Run renderer tests with:

```bash
python3 -m unittest discover -s test/release -v
```

For offline previews, supply a generated body with `--changes`:

```bash
python3 packaging/release/render-notes.py v0.1.13 \
  --changes /tmp/generated-notes.md --output /tmp/release-notes.md
```
