### Managed E2E lifecycle

Prefer `karate_all` for the managed application/test lifecycle after doctor/setup
and authorization for its Docker lifecycle. It owns application cleanup. Do not
use `fail-fast: false` to arrange cleanup around dependent startup/test steps:
that also permits tests after failed prerequisites. For a necessary manual flow,
stop on prerequisite failure and perform authorized cleanup separately. Container
teardown is a separate operation; do not assume `karate_all` performs it.

Before retrying an interrupted/timed-out MCP command, inspect `execution_list`
and `execution_status`. Cancel only matching executions owned by this session,
confirm terminal status, and retry the affected operation. Never reset Docker
merely because a call timed out. See the [common execution rules](../../makevn/SKILL.md#common-policy).

### Strict Karate HTTP readiness

`makevn karate-all` requires a configured or detected application health URL
before starting Docker or packaging. Set `MAKEVN_APP_HEALTH_URL` in
`.makevn/config` when detection cannot identify the correct endpoint.
Resolution remains config, then persisted profile, then generic detection.

Only HTTP 2xx verifies readiness; redirects and other statuses are retried.
`MAKEVN_APP_HEALTH_TIMEOUT` defaults to 60 seconds and must be an integer
between 1 and 2147483647 (without leading zeros). Requests have a 2-second
connection limit and a 5-second total limit, capped by the remaining deadline.
Timeout or application exit prevents Karate from running and preserves the
application log under `.makevn/app/app.log`.

Standalone `run-app-bg` can still start without a health URL, but warns that
only process liveness was checked, not HTTP readiness. Use `karate-test`
directly for an externally managed application. HTTP readiness does not
validate JSON health status, application semantics, or Kafka availability.

### Doctor health configuration prompts

For an initialized runnable application without an explicit health URL,
interactive `makevn doctor` asks to confirm/correct a detected URL or enter
one when detection finds none. The input is prefilled with the detected URL or a suggested URL using the
application port/context and /health. Suggestions are explicitly unverified;
Enter confirms and saves the editable value, while typing skip leaves configuration
unchanged. Earlier compose
or LOCAL_CONTAINERS questions do not suppress the health question.

Nonempty input must use HTTP(S) without whitespace and is saved safely in
`.makevn/config`. Existing explicit URLs are preserved without prompting.
Without a terminal, doctor never requests input and reports how to configure
missing readiness. `profile refresh` remains automatic and noninteractive;
`init --force` does not force these prompts or overwrite existing config.

For `karate-all`, inspect `makevn doctor` for effective application Spring
profiles and their CI source. Selection precedence is `SPRING_PROFILES_ACTIVE`
(explicit empty is respected), `.makevn/config` `MAKEVN_KARATE_APP_PROFILES`,
then unambiguous literal Karate CI detection. No global `standalone,local`
default exists. Noninteractive execution does not prompt or write user config;
resolve ambiguous/dynamic candidates explicitly. The setting affects only the
managed Karate application, not the test JVM or standalone application commands.
