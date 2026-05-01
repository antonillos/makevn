# Distribution

## Current Goal

Prepare two conventional distribution paths without opening the repository yet:

- a manual GitHub prerelease workflow
- a Homebrew formula ready to move into a dedicated tap later

## Manual GitHub Test Releases

This repository now includes a manual workflow:

- `.github/workflows/release-test.yml`

It is intentionally manual through `workflow_dispatch`.

Inputs:

- `version`, for example `v0.1.0-test.1`
- `target_ref`, usually `main`
- `prerelease`
- `draft`

What it does:

- checks out the requested ref
- creates a versioned source archive from the tagged revision
- generates a SHA-256 checksum file
- creates a GitHub release with those assets attached

You can run it from the GitHub Actions UI or with `gh`:

```bash
gh workflow run release-test.yml -f version=v0.1.0-test.1 -f target_ref=main -f prerelease=true -f draft=false
```

Current note while the repository remains private:

- the release is fine for internal testing
- release assets are not a public distribution channel yet

## Homebrew Preparation

This repository now includes a formula prepared for a future tap:

- `packaging/homebrew/makevn.rb`

The intended conventional layout later is:

1. source repo: `antonillos/makevn`
2. tap repo: `antonillos/homebrew-tap`
3. formula path in the tap: `Formula/makevn.rb`

The formula is currently `head`-only on purpose because:

- the project is still private
- there is no stable public release artifact to pin with `url` and `sha256` yet

The formula builds the Rust frontend from source and installs the runtime layout expected by `makevn`:

- `bin/makevn`
- `libexec/makevn/`
- `share/makevn/`
- `share/makevn/skills/makevn/`

The Rust build entrypoint exposed publicly by this repository is:

- `./build-rust-dispatcher.sh`

## Recommended Next Step Later

When you decide the project is ready for wider distribution:

1. create `antonillos/homebrew-tap`
2. copy `packaging/homebrew/makevn.rb` to `Formula/makevn.rb` in that tap
3. replace the `head` stanza with a stable `url` and `sha256` from a tagged release
4. switch the formula from `head` to versioned release assets when the public release flow is ready

Expected end-user install command later:

```bash
brew install antonillos/tap/makevn
```

## Private-Repo Caveat

As long as `antonillos/makevn` stays private, Homebrew is only prepared technically.

That means:

- the formula is useful as a base
- the release workflow is useful for internal testing
- the normal public Homebrew flow should wait until the repository and release assets are ready to be public
