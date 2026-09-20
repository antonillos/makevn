# Release Process

## Version source

The canonical version is the `version` field in
`rust/dispatcher/Cargo.toml`. Release tags use the same version prefixed with
`v`.

## Standard release

1. Ensure the intended changes have reached `develop` and promote `develop` to
   `main` through the protected PR process.
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
