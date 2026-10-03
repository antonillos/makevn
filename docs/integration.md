# Standalone initialization and legacy retirement

Run `makevn doctor`, then `makevn init` when initialization is missing.
The public CLI and MCP never invoke or interpret repository Makefiles.
New initialization creates `.makevn/` only; no Make targets are generated.

## Upgrade old installations

Run `makevn doctor`, then preview `makevn init --force --dry-run`.
Apply with `makevn init --force` or `makevn refresh`. Both preserve user config
and update the initialization build. `profile refresh` updates only the profile.

Migration preflights all legacy ownership records and artifacts before writing.
It removes only exact known managed include blocks, unchanged generated bootstrap
files, and recognized historical makevn template bodies. Other repository targets
are preserved byte-for-byte. Paths outside the known repository locations and
symbolic links used as migration artifacts are rejected.

Modified, incomplete, or ambiguous artifacts stop migration without changing any
files. Preserve your custom content, manually remove the legacy include/block and
`.makevn/makevn.mk`, and clear the corresponding legacy ownership fields from both
`.makevn/manifest` and `.makevn/state.json` before retrying. Never delete user-owned
targets. Make commands and MCP tools from older releases are no longer supported.

`makevn uninstall --dry-run` previews the same retirement checks. `makevn uninstall`
retires recognized artifacts before removing `.makevn/`; ambiguous artifacts block
uninstall too, preventing dangling includes and destructive cleanup.

If local container defaults previously came from Makefile variables, configure
`MAKEVN_LOCAL_CONTAINERS` in `.makevn/config` or explicitly export
`LOCAL_CONTAINERS`. Makefile variables no longer affect makevn.
