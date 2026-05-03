# Example: Existing Makefile

Repository shape:

- `pom.xml` present
- `Makefile` already exists

Recommended flow:

```bash
makevn doctor
makevn init
makevn make install
make -f .makevn/makevn.mk vn-doctor
```

Only use this if the user explicitly wants to edit the existing makefile:

```bash
makevn make install
```
