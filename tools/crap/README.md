# Internal CRAP ratchet

The required `crap` job gates authored production Rust and Bash independently,
separate from the `smoke` job.
Generated JavaScript and JavaScript tests are deliberately excluded; add a third
language baseline if authored production JavaScript is introduced.

## Local prerequisites

- `cargo-llvm-cov` 0.9.1
- `cargo-crap` 0.4.3
- Ruby 3.3 with `bashcov` 3.1.3
- Bash 4 or newer
- ShellMetrics 0.5.0 (commit `b3bfff2af6880443112cdbf2ea449440b30ab9b0`)

On macOS, set `MAKEVN_CRAP_BASH` when the default `/bin/bash` is older than 4:

```bash
export MAKEVN_CRAP_BASH="$(brew --prefix)/bin/bash"
```

Run each language check before committing changes to a pull request, including
changes made in response to review comments:

```bash
tools/crap/rust-crap.sh
tools/crap/shell-crap.sh
tools/crap/run.sh
```

The combined command writes JSON, Markdown, SARIF, summary, per-language reports,
and `badge.json` under `target/crap/`. Missing coverage, empty reports, and path
mismatches are infrastructure errors. A baseline can decrease in a pull request,
but CI rejects changes that increase either language limit relative to its base.
