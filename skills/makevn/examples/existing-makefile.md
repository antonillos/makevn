# Example: Existing Makefile

A repository with `pom.xml` and a user-owned Makefile uses the same standalone flow:

```bash
makevn doctor
makevn init
makevn verify
```

makevn does not interpret, execute, or add targets to that Makefile.
For an old generated integration, preview `makevn init --force --dry-run`, then
apply with `makevn init --force`; modified artifacts require manual resolution.
