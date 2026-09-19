"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/prepare-release.yml"), "utf8");

test("dispatches revision-bound commit policy for release PRs", () => {
  assert.match(workflow, /permissions:\n  actions: write/);
  assert.match(workflow, /GH_TOKEN: \$\{\{ secrets\.MAKEVN_RELEASE_TOKEN \}\}/);
  assert.match(workflow, /GH_TOKEN="\$\{\{ github\.token \}\}" gh workflow run commit-policy\.yml/);
  assert.match(workflow, /gh workflow run commit-policy\.yml/);
  assert.match(workflow, /--ref "\$\{branch\}"/);
  assert.match(workflow, /-f pull_number=/);
  assert.match(workflow, /-f head_sha=/);
  assert.match(workflow, /-f base_sha=/);
  assert.match(workflow, /-f base_ref=/);
});

test("refreshes the PR number after creating or replacing a release PR", () => {
  assert.match(workflow, /if \[\[ -z "\$\{pr_number\}" \|\| "\$\{pr_state\}" != "OPEN" \]\]; then/);
  assert.match(workflow, /pr_number="\$\(gh pr view "\$\{branch\}" .* --json number --jq '\.number'\)"/);
});
