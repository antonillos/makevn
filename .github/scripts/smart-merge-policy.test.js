"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/smart-merge.yml"), "utf8");

test("Verify runs for intermediate stack bases and Smart Merge consumes each layer", async () => {
  const verify = readFileSync(resolve(__dirname, "../workflows/verify.yml"), "utf8");
  const prTrigger = verify.match(/^  pull_request:(.*(?:\n(?: {4,}.*|\s*))*)/m);
  assert.ok(prTrigger, "Verify must run on pull_request events");
  assert.doesNotMatch(prTrigger[1], /branches(?:-ignore)?:/,
    "intermediate feature branches must receive automatic PR validation");

  assert.match(prTrigger[1], /types: \[opened, synchronize, reopened, edited\]/);

  const functionStart = workflow.indexOf("async function findSuccessfulVerify(target) {");
  const functionEnd = workflow.indexOf("\n\n            // Reuse", functionStart);
  assert.ok(functionStart >= 0 && functionEnd > functionStart);
  const findSuccessfulVerify = new Function("github", "loadRequiredJobs", "owner", "repo",
    `${workflow.slice(functionStart, functionEnd)}; return findSuccessfulVerify;`);
  const requests = [];
  const loaded = [];
  const github = { rest: { actions: { listWorkflowRuns: async (request) => {
    requests.push(request);
    return { data: { workflow_runs: [
      { id: 1, head_sha: "stale" },
      { id: 2, head_sha: request.branch + "-sha", pull_requests: [
        { number: 7, base: { ref: "develop", sha: "base-sha" } },
      ] },
    ] } };
  } } } };
  const lookup = findSuccessfulVerify(github, async (id) => {
    loaded.push(id);
    return { invalid: [] };
  }, "example", "repo");
  for (const branch of ["codex/bottom", "codex/middle", "codex/top"]) {
    const run = await lookup({ number: 7, base: { ref: "develop", sha: "base-sha" },
      head: { ref: branch, sha: branch + "-sha" } });
    assert.equal(run.id, 2);
  }
  for (const target of [
    { number: 8, base: { ref: "develop", sha: "base-sha" } },
    { number: 7, base: { ref: "codex/bottom", sha: "base-sha" } },
    { number: 7, base: { ref: "develop", sha: "new-base-sha" } },
  ]) {
    assert.equal(await lookup({ ...target,
      head: { ref: "codex/top", sha: "codex/top-sha" } }), null);
  }
  assert.deepEqual(loaded, [2, 2, 2]);
  assert.deepEqual(requests.slice(0, 3).map((request) => request.branch),
    ["codex/bottom", "codex/middle", "codex/top"]);
  for (const request of requests) {
    assert.equal(request.workflow_id, "verify.yml");
    assert.equal(request.event, "pull_request");
    assert.equal(request.status, "success");
  }
});

test("missing intermediate verification stops the stack before merge", async () => {
  const start = workflow.indexOf("for (const target of targetPulls) {",
    workflow.indexOf("// Reuse a complete successful"));
  const end = workflow.indexOf("let verifyRun = await findSuccessfulVerify(pull);", start);
  assert.ok(start >= 0 && end > start);
  const validate = new Function("targetPulls", "pullNumber", "findSuccessfulVerify",
    "comment", "core", `return (async () => {
      ${workflow.slice(start, end)}
      return "merge-reached";
    })();`);
  const pulls = [1, 2, 3].map((number) => ({ number, head: { sha: "sha" + number } }));
  const visited = [];
  const failures = [];
  const result = await validate(pulls, 3, async (target) => {
    visited.push(target.number);
    return target.number === 1 ? { id: 10 } : null;
  }, async () => {}, { setFailed: (message) => failures.push(message) });
  assert.equal(result, undefined);
  assert.deepEqual(visited, [1, 2]);
  assert.deepEqual(failures, ["Stack PR #2 is not verified."]);
  assert.equal(await validate(pulls, 3, async () => ({ id: 10 }),
    async () => {}, { setFailed: assert.fail }), "merge-reached");
});

test("text edits skip expensive checks in a separate concurrency group", () => {
  const verify = readFileSync(resolve(__dirname, "../workflows/verify.yml"), "utf8");
  const condition = verify.match(/  smoke:\n    name: .*\n    if: (.*)/)[1];
  assert.match(verify, new RegExp(`  crap:\\n    name: .*\\n    if: ${condition.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
  const evaluate = (expression, github) => new Function("github", `return (${expression});`)(github);
  const group = verify.match(/  group: (.*)/)[1];
  const render = (github) => group.replace(/\$\{\{ (.*?) \}\}/g,
    (_, expression) => String(evaluate(expression, github)));
  const event = { workflow: "Verify", ref: "branch", run_id: 100,
    event: { action: "synchronize", pull_request: { number: 1 }, changes: {} } };
  assert.ok(evaluate(condition, event));
  const textEdit = { ...event, run_id: 101, event: { ...event.event,
    action: "edited", changes: { title: { from: "Old" } } } };
  assert.ok(!evaluate(condition, textEdit));
  assert.notEqual(render(textEdit), render(event));
  const baseEdit = { ...textEdit, event: { ...textEdit.event, changes: { base: {} } } };
  assert.ok(evaluate(condition, baseEdit));
  for (const job of ["smoke", "crap"]) {
    const name = verify.split("  " + job + ":\n    name: ")[1].split("\n")[0];
    const expression = name.slice(3, -2);
    assert.equal(evaluate(expression, event), job);
    assert.equal(evaluate(expression, baseEdit), job);
    assert.notEqual(evaluate(expression, textEdit), job);
  }
  assert.equal(render(baseEdit), render(event));
});

test("base advancing immediately before merge blocks the request", async () => {
  const start = workflow.indexOf("for (const target of targetPulls) {",
    workflow.indexOf("// Refresh immediately before merging"));
  const end = workflow.indexOf("const mergeOptions =", start);
  assert.ok(start >= 0 && end > start);
  const check = new Function("targetPulls", "pullNumber", "refreshed", "github", "comment", "core",
    `const owner = "example", repo = "repo";
     return (async () => { ${workflow.slice(start, end)} return "merge-reached"; })();`);
  const target = { number: 1, state: "open", head: { sha: "head" },
    base: { ref: "develop", sha: "validated-base" } };
  for (const number of [1, 2]) {
    const current = { ...target, number, base: { ...target.base, sha: "advanced-base" } };
    const failures = [];
    const result = await check([{ ...target, number }], 1, current,
      { rest: { pulls: { get: async () => ({ data: current }) } } },
      async () => {}, { setFailed: (message) => failures.push(message) });
    assert.equal(result, undefined);
    assert.equal(failures.length, 1);
  }
  assert.equal(await check([target], 1, target, {}, async () => {},
    { setFailed: assert.fail }), "merge-reached");
});

test("squash merges use the validated conventional pull request title", () => {
  assert.match(workflow, /mergeOptions\.commit_title = pull\.title;/);
  assert.doesNotMatch(workflow, /commit_title = `\$\{pull\.title\} \(#\$\{pullNumber\}\)`/);
});

test("workflow identity approves maintainer-authored PRs", () => {
  assert.match(workflow, /if \(targetAuthorIsWorkflowBot\)/);
  assert.doesNotMatch(workflow, /actor === targetAuthor \|\| targetAuthorIsWorkflowBot/);
  assert.match(workflow, /github\.rest\.pulls\.createReview/);
});

test("Smart Merge requires both smoke and CRAP gates", () => {
  assert.match(workflow, /const requiredChecks = \["smoke", "crap"\];/);
});

test("Smart Merge dispatches Verify with a base ratchet and no badge publication", () => {
  assert.match(workflow, /workflow_id: "verify\.yml",[\s\S]*base_ref: pull\.base\.ref,[\s\S]*publish_badge: "false"/);
});

test("release App performs the merge while the workflow bot keeps approval duties", () => {
  assert.match(workflow, /id: merge-app-token/);
  assert.match(workflow, /client-id: \$\{\{ vars\.RELEASE_APP_CLIENT_ID \}\}/);
  assert.match(workflow, /private-key: \$\{\{ secrets\.RELEASE_APP_PRIVATE_KEY \}\}/);
  assert.match(workflow, /permission-contents: write/);
  assert.match(workflow, /permission-pull-requests: write/);
  assert.match(workflow, /permission-workflows: write/);
  assert.match(workflow, /github-token: \$\{\{ github\.token \}\}/);
  assert.match(workflow, /const mergeGithub = getOctokit\(process\.env\.MERGE_APP_TOKEN\)/);
  assert.match(workflow, /mergeRequest = await mergeGithub\.request\(\s*"PUT \/repos\/\{owner\}\/\{repo\}\/pulls\/\{pull_number\}\/merge-async"/);
});

test("App-authenticated merge relies on push triggers instead of duplicate dispatches", () => {
  assert.doesNotMatch(workflow, /workflow_id: "release\.yml"/);
  assert.doesNotMatch(workflow, /workflow_id: "sync-main-to-develop\.yml"/);

  const verify = readFileSync(resolve(__dirname, "../workflows/verify.yml"), "utf8");
  const release = readFileSync(resolve(__dirname, "../workflows/release.yml"), "utf8");
  const sync = readFileSync(resolve(__dirname, "../workflows/sync-main-to-develop.yml"), "utf8");
  assert.match(verify, /push:\s*\n\s*branches:\s*\n\s*- develop/);
  assert.match(release, /push:\s*\n\s*branches:\s*\n\s*- main/);
  assert.match(sync, /push:\s*\n\s*branches:\s*\n\s*- main/);
  assert.doesNotMatch(sync, /workflow_run:/);
});

test("branch cleanup ignores only an already-deleted reference", () => {
  assert.match(workflow, /const alreadyDeleted = \[404, 422\]\.includes\(error\.status\) &&/);
  assert.match(workflow, /Reference does not exist\/i\.test\(error\.message\)/);
  assert.match(workflow, /if \(!alreadyDeleted\) \{\s*core\.warning\(`Could not delete/);
});
