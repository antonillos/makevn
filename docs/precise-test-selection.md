# Precise test selection within a Maven module

Status: proposed; no runtime behavior is implemented by this document.

## Problem

A production change currently selects the complete owner module suite. In Commons
Lang, changing `BitField.isSet(int)` therefore selects 98,762 test cases. Named
tests provide quick feedback but do not publish the focused evidence used by
coverage-changes and crap-changes.

## Proposed behavior

Retain focused preview and execution as the public workflow. Narrow an owner
suite only when MakeVN has a complete, validated test-to-production evidence map.
Select tests covering changed classes and their known transitive consumers.
Always include changed tests. Preserve separate Surefire and Failsafe selectors,
dependency preparation, fresh report checks and coverage snapshot publication.

For a BitField change, the expected selected tests include BitFieldTest,
BitFieldLongTest and every other test whose validated evidence reaches BitField
or a consumer. Never assume that these two named classes are sufficient.

## Evidence contract

Introduce versioned, disposable internal evidence, produced by an instrumented
complete owner suite. Record individual test class identities and plugin ownership,
per-test-class execution coverage, a production dependency graph and the complete
test inventory. Aggregate JaCoCo XML alone cannot establish test identities.

Record the baseline Git revision, production and test source fingerprints, compiled
class hashes, reactor model, effective test configuration, dependencies, JDK and
instrumentation versions. Execution must validate compatibility with this baseline;
an unrecognized difference must invalidate narrowing. Do not trust a user-created
map merely because it has the right filename or schema version.

Use isolated execution data per test class; concurrent or forked executions must
not mix identities. Nested and parameterized cases belong to their owning test
class. A failed, interrupted, empty or skipped baseline cannot establish completeness.
Cross-module consumers require explicit validated graph edges and test inventories;
unresolved edges invalidate narrowing for affected owners.

Before narrowing, classify the diff. New/deleted classes, changed public contracts,
resources, POMs, test helpers, generated sources and changed test configuration use
complete owner suites until their impact can be proven. New dependency edges and
dynamic behavior require conservative expansion; reflection, service loading and
unresolved generated code must not silently disappear from the consumer graph.

## Conservative fallback

Missing, stale, partial, incompatible or ambiguous evidence selects the complete
owner suite. The preview states the owner and a specific reason, such as missing
per-test coverage, changed configuration, or unresolved dynamic consumer. A valid
map with no matching test also falls back; it does not produce an empty success.
Do not silently widen to other modules or change focused versus exhaustive mode.

The preview lists selected test classes, evidence provenance and fallback reasons.
Execution recomputes the plan and revalidates evidence. A narrowed successful run
publishes a fresh focused UT/IT and changed-class bytecode snapshot for both metric
commands. Global coverage and full CI remain separate gates.

## Implementation and acceptance

1. Add evidence capture and validation independently of selection. Establish the
   completeness rules with Surefire/Failsafe, forks, parameterized tests and failed
   or interrupted captures. Do not narrow tests during this stage.
2. Add dependency and consumer expansion with explicit unknown-edge diagnostics.
3. Add planner narrowing only when all prerequisites are validated. Cover direct
   tests, indirect consumers, changed tests and every invalidation/fallback case.
4. Repeat the Commons Lang fixture on the same revision and JDK. First establish
   a successful complete baseline; its current timezone test failures prevent that.
   Inspect preview, actual fresh test reports, changed-class coverage and CRAP
   from the same successful focused run. Report exact selected classes and counts.
5. Update CLI/MCP guidance and the test/quality skills together. Require the PR CI
   CRAP gate before merge.

No test-count reduction or metric correctness claim is established until the
fixture scenario passes. Test names and source imports alone are insufficient
evidence for this feature.
