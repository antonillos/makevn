# Example: Existing Makefile

Repository shape:

- `pom.xml` present
- `Makefile` already exists

Recommended flow:

```bash
makevn doctor
makevn init --mode make-include
make -f .makevn/makevn.mk vn-doctor
```

Only use this if the user explicitly wants to edit the existing makefile:

```bash
makevn init --mode make-include --write-make-include
```
