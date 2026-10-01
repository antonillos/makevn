"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/smart-merge.yml"), "utf8");

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
  assert.match(workflow, /MAKEVN_RELEASE_APP_CLIENT_ID/);
  assert.match(workflow, /MAKEVN_RELEASE_APP_PRIVATE_KEY/);
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
