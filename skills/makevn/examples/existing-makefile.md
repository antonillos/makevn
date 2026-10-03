# Example: Existing Makefile

A repository with `pom.xml` and a user-owned Makefile uses the same standalone flow:

```bash
makevn doctor
makevn init
makevn verify
```

makevn does not inspect, execute, modify, or add targets to that Makefile.
Any old makevn-generated includes or bootstrap files must be cleaned up manually.
