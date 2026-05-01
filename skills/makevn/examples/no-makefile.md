# Example: No Makefile

Repository shape:

- `pom.xml` present
- no `Makefile`
- no `GNUmakefile`

Lowest-risk flow:

```bash
makevn doctor
makevn init --mode standalone
makevn verify
```

If the user wants native `make` support:

```bash
makevn init --mode make-bootstrap
make -f .makevn/makevn.mk vn-doctor
```
