# Local reactor validation, 2026-11-02

Validation used isolated clones of existing local public repositories. Original
checkouts were not edited. Setup used MakeVN MCP doctor/init/configure with the
JDK and repository preferences already saved in the original checkouts.

## Petclinic Microservices

- Revision: `272b0cac71353bbd155ffb8214eb681dcb7c503c`.
- Clone: `/private/tmp/makevn-reactor-validation-petclinic`.
- JDK: local OpenJDK 25.
- Static initialization: 0.757 seconds, 8 modules, 62 Java sources, 8 candidate
  test classes, zero runtime observations. No Maven goals or tests ran at init.
- Edit: append `+ 0` to the return expression of `Vet.getNrOfSpecialties()` in
  `spring-petclinic-vets-service`. This preserves behavior and changes a method
  body without changing its declaration.
- Focused preview: selects only
  `org.springframework.samples.petclinic.vets.web.VetResourceTest` in the vets
  module, leaving the other seven module suites outside the plan.

The first execution prepared dependencies successfully, then exposed an empty
path in the post-preparation scope check when no test files had changed. The
planner now ignores empty entries; a reactor regression reproduces that case.

The installed MCP runtime did not contain this fix. After completing MCP setup,
the patched runtime was exercised through the public MakeVN CLI with
`MAKEVN_INSTALL_ROOT` pointing to the source checkout. The global installation
was not modified. Maven required access to its local artifact cache.

```bash
MAKEVN_INSTALL_ROOT=/path/to/makevn makevn --repo /path/to/clone --compact verify-changes-preview --focused
MAKEVN_INSTALL_ROOT=/path/to/makevn makevn --repo /path/to/clone --compact verify-changes --focused
```

Result: focused verification passed in approximately 19 seconds including
MakeVN analysis/coordination. Maven reported approximately 2.1 seconds for
preparation and 4.9 seconds for owner verification. The fresh Surefire report
contains 1 test, 0 failures, 0 errors and 0 skipped tests. These are local warm-cache
timings, not cold-build guarantees or full integration verification.

The saved `progressive-reactor-v1` map contains one observation keyed by
`spring-petclinic-vets-service::org.springframework.samples.petclinic.vets.web.VetResourceTest`.
Its execution-wide dependency superset contains six production classes: `Vet`,
`Specialty`, `VetRepository`, `VetResource`, `VetsProperties` and
`VetsServiceApplication`, all qualified by the vets module. No test replay was
needed to collect this evidence.

Local evidence remains in the clone's `.makevn/test-impact/progressive.json`,
`.makevn/logs/verify-changes-{1,2}.log` and the vets module's
`target/surefire-reports/TEST-org.springframework.samples.petclinic.vets.web.VetResourceTest.xml`.

## Karate: conservative fallback

- Revision: `2df3f1778021c50096a5911cfff377c4350c32a4`.
- Clone: `/private/tmp/makevn-reactor-validation-karate`.
- Static initialization refuses class narrowing because Gatling/profiling modules
  declare additional Java source roots (`add-source` / `add-test-source`).
- A method-body edit to `Pair.toString()` in `karate-js` produces a successful
  focused preview retaining complete suites for its seven consumer/owner modules.
  No Karate tests or containers were started.

Earlier syntax-only timing from the local Karate checkout was not evidence that
its clean committed layout supported class narrowing. This clean-clone exercise
validates the fallback instead. Neither fixture establishes that every reactor
layout is supported or replaces the PR smoke/CRAP gates.

## JGraphT: standard source layout with custom test inventory

- Revision: `f75281cb3127ff8dfee56302260905fcc6a0ca90`.
- Clone: `/private/tmp/makevn-reactor-validation-jgrapht`.
- Public installed MakeVN build: `0.4.0 (2026.11.02.14.24)`, exercised through MCP.
- Static initialization: 1.715 seconds, 9 modules, 1,006 Java sources and 363
  candidate test classes. No tests ran during initialization.
- Neutral edit: replace the explicit generic constructor argument with the
  diamond operator in `ElementOrderMethod.guavaComparator()`.
- Preview retains full suites for `jgrapht-guava` and its consumer `jgrapht-dist`.
  Surefire/Failsafe filters configured in the core module prevent class narrowing.
- Real focused verification passed in 34.768 seconds: 32 tests across six fresh
  Guava test reports, zero failures, errors or skipped tests. Preparation installed
  upstream outputs without tests; owner verification ran without `-am`.
- Preparation generates ANTLR Java sources in `jgrapht-io`. Runtime enrichment
  therefore remains unavailable, and the map has zero observations. This validates
  standard-layout initialization and conservative real verification, not precise
  selection or learning for generated-source projects.

Evidence remains in the clone's `.makevn/logs/verify-changes-{1,2,3}.log` and
`jgrapht-guava/target/surefire-reports/TEST-*.xml`. No fixture POMs, test filters or
quality thresholds were changed.
