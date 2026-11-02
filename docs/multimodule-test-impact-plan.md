# Proposed progressive impact support for Maven reactors

Status: design only. Reactor verification currently selects modules and runs
complete owner suites. Automatic static initialization does not enable test-class
narrowing in a reactor.

## Existing components

- `changes_scope.declared_modules` resolves literal unconditional modules.
- `reactor_impact.reactor_consumers` computes reverse dependency closure, including
  inherited/profile dependencies, local plugins and parent relationships. Unknown
  coordinates remain a reason to retain broad verification.
- `changes_scope.focused_plan` already emits one owner/test selection per module.
- `progressive_impact.narrow` explicitly rejects reactor owners, and
  `test_impact.validate_layout` rejects aggregator layouts. The runtime observer
  consequently passes reactor executions through without learning observations.

Removing these guards alone would be unsafe: root-relative source paths,
unqualified class identities and one module's report directory are assumptions
throughout the current map format and observation pipeline.

## Suggested implementation sequence

1. Introduce a versioned reactor map with module-relative source paths and
   `(module, fully qualified class)` identities. Parse Java once per supported
   module and preserve the current single-module behavior. Aggregators without
   sources contribute Maven relationships, not candidate tests.
2. Use the existing consumer closure to choose eligible owners before narrowing
   test classes. Resolve source references only through visible module
   dependencies. Retain every matching candidate for ambiguous names and keep
   complete consumer suites when ownership or dependency resolution is uncertain.
3. Feed owner-specific selections into the existing focused plan. Preparation
   must build required upstream outputs once; tests must not rebuild package or
   Shade artifacts for every selected class. Revalidate generated-source and
   input changes after preparation.
4. Collect fresh reports and loaded-class traces for each module during normal
   executions. Attribute observations by module and class origin. When a shared
   JVM prevents precise attribution, retain execution-wide additive supersets;
   never infer that an unobserved dependency is absent.
5. Invalidate observations when reactor membership, Maven coordinates, parent
   configuration, Java context, source declarations or dependency artifacts
   change. Merge compatible observations under the existing atomic lock model.

## Required verification before enabling narrowing

- Chain `core -> service -> app`: a core method edit includes downstream tests;
  an unrelated module stays outside the plan only with proven ownership.
- Duplicate class names, nested classes, shared test fixtures and test JARs do
  not collapse module identities or lose consumers.
- Inherited dependencies and profiles either produce a conservative closure or
  visibly retain complete suites. Unknown settings, generated sources, unresolved
  coordinates and custom test filters retain the existing fallback.
- Reports from stale executions, another module, skipped tests or failed suites
  cannot establish successful runtime evidence for the selected owner.
- Init and preview execute no Maven goals or tests. Runtime learning never
  replays tests. Repeated initialization preserves compatible observations.
- Validate on isolated real reactor fixtures, including Petclinic Microservices
  and Karate, then require the PR smoke and CRAP gates before merging.

The first release should support literal local reactors with standard source
layouts. Extending Maven model resolution and supporting generated Java should
remain separate work; neither is required to make this initial scope useful.
