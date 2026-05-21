# Release Process

## Version sources

| Artifact | Location | Source of truth |
|----------|----------|-----------------|
| makevn binary | `rust/dispatcher/Cargo.toml` | `version` field |
| MCP server | `makevn-mcp` Rust binary | inherits from `Cargo.toml` |
| Homebrew formula | `antonillos/homebrew-tap/Formula/makevn.rb` | References release tag |

The canonical version lives in `Cargo.toml`. The `bump-version.sh` script updates
all locations from a single invocation.

## Version scheme

- **Development**: `0.x.0-dev` (e.g. `0.2.0-dev`)
- **Release**: `0.x.0` (e.g. `0.1.0`)
- **Patch**: `0.x.y` (e.g. `0.1.1`)

## Full release workflow

### 1. Bump version

```bash
# From the repository root
./bump-version.sh 0.1.0
```

This updates:
- `rust/dispatcher/Cargo.toml`
- `packaging/homebrew/makevn.rb` (stable URL, SHA placeholder)
- `../homebrew-tap/Formula/makevn.rb` (if present locally)

### 2. Commit and tag

```bash
git add -p
git commit -m "release: bump to 0.1.0"
git tag v0.1.0
git push origin main --tags
```

Tag format: `v` followed by the Cargo.toml version (e.g. `v0.1.0`).

### 3. Create GitHub release

Via the Actions UI or CLI:

```bash
gh workflow run release.yml \
  -f version=v0.1.0 \
  -f target_ref=main \
  -f prerelease=false \
  -f draft=false
```

The workflow:
- validates the version format
- builds the Rust dispatcher and `makevn-mcp` (Linux x86_64)
- creates the source archive and SHA-256
- creates a GitHub release with all assets

### 4. Update Homebrew formula

After the release is live, download the source archive and compute its SHA-256:

```bash
# Get SHA from the release
gh release download v0.1.0
shasum -a 256 makevn-v0.1.0.tar.gz
```

Then update both formula copies:

- `../homebrew-tap/Formula/makevn.rb`
- `packaging/homebrew/makevn.rb`

Replace the placeholder `sha256 "TBD_AFTER_RELEASE"` with the actual hash.

```bash
cd ../homebrew-tap
git add Formula/makevn.rb
git commit -m "makevn: update to v0.1.0"
git push
```

## Development workflow

During normal development, the version in `Cargo.toml` stays as `0.x.0-dev`.
The build script appends a timestamp automatically:

```text
0.2.0-dev (2026.05.12.22.30)
```

No version bump or tag needed for day-to-day changes.

## Testing a release

Create a prerelease first to verify the workflow:

```bash
./bump-version.sh 0.1.0-test.1
git add -A && git commit -m "release: test 0.1.0-test.1"
git tag v0.1.0-test.1
git push origin main --tags
gh workflow run release.yml -f version=v0.1.0-test.1 -f prerelease=true
```

## Quick reference

```bash
# Bump
./bump-version.sh <version>

# Tag and push
git tag v<version>
git push origin main --tags

# Release (choose one)
gh workflow run release.yml -f version=v<version> -f target_ref=main

# Post-release
cd ../homebrew-tap && git add Formula && git commit -m "makevn: update to v<version>" && git push
```
