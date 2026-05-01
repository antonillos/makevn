# Integration Modes

These modes are stable product concepts and remain valid across the planned Rust frontend transition. The frontend implementation may change, but the repo integration model should not.

## `standalone`

Use only the CLI:

```bash
makevn doctor
makevn build
makevn verify
```

This does not touch `Makefile` or `GNUmakefile`.

This is still the safest mode for:

- first-time users
- AI agents that want the least invasive adoption path
- repos where `make` integration is not needed

## `make-include`

Generate `.makevn/makevn.mk` and keep any existing root make entrypoint intact.

Use it directly:

```bash
make -f .makevn/makevn.mk vn-doctor
```

Or add an explicit include yourself:

```make
include .makevn/makevn.mk
```

Optional edit through `makevn` itself:

```bash
makevn init --mode make-include --write-make-include
```

`makevn` will refuse this automatic edit if both `Makefile` and `GNUmakefile` exist, because that would be ambiguous.

This remains the recommended mode when a repo already has a make entrypoint and the user wants optional namespaced `vn-*` targets.

## `make-bootstrap`

Use this only when the repo has no `Makefile` and no `GNUmakefile`.

```bash
makevn init --mode make-bootstrap
```

This creates a minimal root `Makefile` that delegates to `.makevn/makevn.mk`.

Use this only as an explicit opt-in when the repo has no existing make entrypoint and the user actually wants one.

## Uninstall

Always use:

```bash
makevn uninstall
```

Preview first if needed:

```bash
makevn uninstall --dry-run
```

## Agent Notes

- agents should still run `makevn doctor` before recommending one of these modes
- when structured output becomes available for a command, agents should prefer `--json`
- these integration modes are independent from the future Rust frontend, so adoption guidance should stay stable
