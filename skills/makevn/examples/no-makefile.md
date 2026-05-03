# Example: No Makefile

Repository shape:

- `pom.xml` present
- no `Makefile`
- no `GNUmakefile`

Lowest-risk flow:

```bash
makevn doctor
makevn init
makevn verify
```

If the user wants native `make` support:

```bash
makevn init
makevn make install
make -f .makevn/makevn.mk vn-doctor
```
