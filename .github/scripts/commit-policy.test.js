"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

// Exercise the exact API-only workflow script, not a duplicate policy parser.
const workflow = readFileSync(resolve(__dirname, "../workflows/commit-policy.yml"), "utf8");
const script = workflow.split("          script: |\n")[1]
  .split("\n").map((line) => line.replace(/^ {12}/, "")).join("\n");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction("github", "context", "core", script);
const sha = (n) => n.toString(16).padStart(40, "0");
const signed = (n = 1, message = "docs: update guide", signatureType = "SSH") => ({
  sha: sha(n), message,
  parents: [{ sha: sha(n + 1000) }],
  verification: { verified: true, reason: "valid", signature: `-----BEGIN ${signatureType} SIGNATURE-----\nsynthetic` },
});
const repositoryCommit = (commit) => ({
  sha: commit.sha,
  parents: commit.parents,
  committer: commit.committer,
  commit: { message: commit.message, verification: commit.verification },
});

async function check(commits = [signed()], options = {}) {
  const expected = { number: 193, head: { sha: commits.at(-1)?.sha || sha(1) },
    base: { sha: sha(999), ref: "develop" }, commits: commits.length };
  const logs = [];
  const requests = [];
  let reads = 0;
  const listCommits = () => { throw new Error("Must paginate"); };
  const github = {
    rest: {
      pulls: {
        listCommits,
        get: async () => ({ data: ++reads === 1 ? { ...expected, ...options.before } :
          { ...expected, ...options.after } }),
      },
      repos: { getCommit: async ({ ref }) => {
        requests.push(ref);
        if (options.apiError) throw new Error("PRIVATE_API_PAYLOAD");
        return { data: repositoryCommit(options.object || commits.find((commit) => commit.sha === ref)) };
      } },
    },
    paginate: async (endpoint, params) => {
      assert.equal(endpoint, listCommits);
      assert.equal(params.per_page, 100);
      return options.list || commits;
    },
  };
  const core = {
    error: (value) => logs.push(["error", value]),
    setFailed: (value) => logs.push(["failed", value]),
    summary: {
      addHeading() { return this; },
      addRaw(value) { logs.push(["summary", value]); return this; },
      async write() {},
    },
  };
  await run(github, { repo: { owner: "example", repo: "example" },
    payload: { pull_request: expected } }, core);
  return { failed: logs.some(([kind]) => kind === "failed"), logs, requests };
}

test("accepts conventional headers, custom types, scopes, breaking markers and bodies", async () => {
  for (const message of ["fix: repair issue", "FEAT(api)!: change contract", "security: tighten validation",
    "revert: undo change", "docs: guide\n\nBody\n\nRefs: #1", "feat!: change API\n\nBREAKING CHANGE: renamed",
    "fix: repair\r\n\r\nBody", "chore(deps): update", "docs: guide\n"]) {
    assert.equal((await check([signed(1, message)])).failed, false, message);
  }
});

test("rejects malformed messages including fixup, single-parent merge and missing blank line", async () => {
  for (const message of ["", null, "update docs", "fix:no space", "fix: ", "fix: \t",
    "fix(): repair", "fix( ): repair", "fix(scope: repair", "fix! (scope): repair", "fixup! fix: repair",
    "Merge branch 'develop'", "fix: repair\nbody without separator", "fix: repair\rpayload"]) {
    assert.equal((await check([signed(1, message)])).failed, true);
  }
});

test("accepts recognized merge headers only for multi-parent commits", async () => {
  const merge = signed(1, "Merge branch 'feature' into develop");
  merge.parents = [{ sha: sha(2) }, { sha: sha(3) }];
  assert.equal((await check([merge])).failed, false);
  assert.equal((await check([signed(1, "Merge branch 'feature' into develop")])).failed, true);
});

test("exempts only GitHub-generated merge commits from signature validation", async () => {
  const merge = signed(1, "Merge branch 'feature' into develop");
  merge.parents = [{ sha: sha(2) }, { sha: sha(3) }];
  merge.committer = { login: "web-flow", type: "User" };
  merge.verification = undefined;
  assert.equal((await check([merge])).failed, true);

  const githubMerge = signed(1, "Merge pull request #42 from example/feature\n\nfeat: merge feature");
  githubMerge.parents = [{ sha: sha(2) }, { sha: sha(3) }];
  githubMerge.committer = { login: "web-flow", type: "User" };
  githubMerge.verification = undefined;
  assert.equal((await check([githubMerge])).failed, false);

  const forged = signed(1, "Merge pull request #42 from example/feature");
  forged.parents = [{ sha: sha(2) }, { sha: sha(3) }];
  forged.committer = { login: "attacker", type: "User", email: "noreply@github.com" };
  forged.verification = undefined;
  assert.equal((await check([forged])).failed, true);
});

test("requires verified PGP or SSH signatures, not Signed-off-by or signature presence", async () => {
  for (const verification of [undefined, null, {},
    { verified: false, reason: "unsigned" },
    { verified: false, reason: "invalid", signature: "-----BEGIN SSH SIGNATURE-----" },
    { verified: true, reason: "gpgverify_unavailable", signature: "-----BEGIN SSH SIGNATURE-----" },
    { verified: "true", reason: "valid", signature: "-----BEGIN SSH SIGNATURE-----" },
    { verified: true, reason: "valid", signature: "-----BEGIN OTHER SIGNATURE-----" }]) {
    const commit = signed(1, "docs: guide\n\nSigned-off-by: synthetic");
    commit.verification = verification;
    assert.equal((await check([commit])).failed, true);
  }
  assert.equal((await check([signed(1, "docs: guide", "PGP")])).failed, false);
});

test("checks every commit, including an invalid earlier commit", async () => {
  const result = await check([signed(1, "not conventional"), signed(2)]);
  assert.equal(result.failed, true);
  assert.deepEqual(result.requests, [sha(1), sha(2)]);
});

test("uses paginated complete metadata for more than one page", async () => {
  for (const length of [101, 250]) {
    const result = await check(Array.from({ length }, (_, i) => signed(i + 1)));
    assert.equal(result.failed, false);
    assert.equal(result.requests.length, length);
  }
});

test("fails closed for empty, over-limit or malformed counts", async () => {
  for (const commits of [0, 251, undefined, 1.5, "1"]) {
    const result = await check([signed()], { before: { commits } });
    assert.equal(result.failed, true);
    assert.equal(result.requests.length, 0);
  }
});

test("rejects truncated, duplicate, malformed or wrong-head commit sets", async () => {
  for (const list of [[signed(1)], [signed(1), signed(1)],
    [signed(1), { sha: "PRIVATE_INVALID_SHA" }], [signed(1), signed(3)]]) {
    assert.equal((await check([signed(1), signed(2)], { list })).failed, true);
  }
});

test("fails closed for stale head, base or count before and after validation", async () => {
  for (const change of [{ head: { sha: sha(2) } }, { base: { sha: sha(998), ref: "develop" } },
    { base: { sha: sha(999), ref: "main" } }]) {
    assert.equal((await check([signed()], { before: change })).failed, true);
    assert.equal((await check([signed()], { after: change })).failed, true);
  }
  assert.equal((await check([signed()], { after: { commits: 2 } })).failed, true);
});

test("fails on API errors and mismatched commit objects without exposing raw data", async () => {
  for (const options of [{ apiError: true }, { object: signed(2) }]) {
    const result = await check([signed()], options);
    assert.equal(result.failed, true);
    assert.doesNotMatch(JSON.stringify(result.logs), /PRIVATE_API_PAYLOAD/);
  }
});

test("diagnostics contain only SHAs and fixed categories, not message or identity data", async () => {
  const commit = signed(1, "PRIVATE_MESSAGE\nPRIVATE_BODY");
  commit.author = { email: "PRIVATE_EMAIL" };
  commit.verification = { verified: false, reason: "PRIVATE_REASON", payload: "PRIVATE_PAYLOAD",
    signature: "PRIVATE_SIGNATURE" };
  const result = await check([commit]);
  assert.equal(result.failed, true);
  assert.doesNotMatch(JSON.stringify(result.logs), /PRIVATE_/);
  assert.equal(result.logs.filter(([kind]) => kind === "error").length, 2);
});

test("workflow is independent, read-only, unfiltered and does not execute PR code", () => {
  assert.match(workflow, /pull_request:\n    branches: \[develop, main\]/);
  assert.match(workflow, /contents: read\n  pull-requests: read/);
  assert.doesNotMatch(workflow, /pull_request_target:|paths:|paths-ignore:|needs:|: write|secrets\.|actions\/checkout|run:|tools\/crap/);
  assert.equal((workflow.match(/uses:/g) || []).length, 1);
  assert.doesNotMatch(script, /\$\{\{/);
});
