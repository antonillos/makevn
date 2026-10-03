# Standalone initialization

Run `makevn doctor`, then `makevn init` when initialization is missing.
The public CLI and MCP never invoke or interpret repository Makefiles.
Initialization creates `.makevn/` only; no Make targets are generated.

After an upgrade, run `makevn doctor`, then `makevn init --force` or
`makevn refresh` when advised. Both preserve user configuration and update the
initialization build. `profile refresh` updates only the profile.

`makevn uninstall --dry-run` previews removal of `.makevn/`.
`makevn uninstall` removes that state directory, never root Makefiles.

## Old Make integrations

There is no migration, compatibility mode, or automatic cleanup. Commands and MCP
tools for Make integration are removed. Existing Makefile/GNUmakefile files,
managed includes, and bootstrap files are neither inspected nor modified.
If you previously installed Make integration, remove its includes and generated
artifacts manually as appropriate; preserve your own targets. Uninstall removes
`.makevn/`, so any old references to it in Makefiles must be cleaned up manually.

Makefile variables no longer affect makevn. Configure `MAKEVN_LOCAL_CONTAINERS`
in `.makevn/config` or explicitly export `LOCAL_CONTAINERS` when needed.
