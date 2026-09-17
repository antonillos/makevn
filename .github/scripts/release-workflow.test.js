"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/prepare-release.yml"), "utf8");

test("relies on the automatic commit-policy trigger for release PRs", () => {
  assert.doesNotMatch(workflow, /gh workflow run commit-policy\.yml/);
  assert.doesNotMatch(workflow, /-f pull_number=/);
  assert.doesNotMatch(workflow, /-f head_sha=/);
  assert.doesNotMatch(workflow, /-f base_sha=/);
  assert.doesNotMatch(workflow, /-f base_ref=/);
});

test("refreshes the PR number after creating or replacing a release PR", () => {
  assert.match(workflow, /if \[\[ -z "\$\{pr_number\}" \|\| "\$\{pr_state\}" != "OPEN" \]\]; then/);
  assert.match(workflow, /pr_number="\$\(gh pr view "\$\{branch\}" .* --json number --jq '\.number'\)"/);
});
