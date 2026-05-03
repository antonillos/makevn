# Integration Workflow

The repository integration model is intentionally small and stable:

## Initialize `makevn`

```bash
makevn doctor
makevn init
```

`init` creates `.makevn/` and does not touch `Makefile` or `GNUmakefile`.

## Install Make integration

When a repo wants optional `vn-*` make targets:

```bash
makevn make install
```

Behavior:

- if the repo already has a single `Makefile` or `GNUmakefile`, `makevn` adds an include block for `.makevn/makevn.mk`
- if the repo has no make entrypoint, `makevn` creates a minimal root `Makefile`
- if the repo has both `Makefile` and `GNUmakefile`, `makevn` refuses the automatic edit

## Remove Make integration

```bash
makevn make uninstall
```

This removes only the Make integration and keeps `.makevn/` intact.

## Uninstall `makevn`

```bash
makevn uninstall
```

This removes `.makevn/` and any Make integration managed by `makevn`.

## Agent Notes

- agents should run `makevn doctor` before `makevn init`
- agents should prefer `makevn init` as the default adoption path
- agents should only run `makevn make install` when the user explicitly wants Make integration
