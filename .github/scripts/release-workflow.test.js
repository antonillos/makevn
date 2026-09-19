"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/prepare-release.yml"), "utf8");

test("dispatches revision-bound commit policy for release PRs", () => {
  assert.match(workflow, /permissions:\n  actions: write/);
  assert.match(workflow, /uses: actions\/create-github-app-token@v3/);
  assert.match(workflow, /client-id: \$\{\{ vars\.MAKEVN_RELEASE_APP_CLIENT_ID \}\}/);
  assert.match(workflow, /private-key: \$\{\{ secrets\.MAKEVN_RELEASE_APP_PRIVATE_KEY \}\}/);
  assert.match(workflow, /permission-contents: read/);
  assert.match(workflow, /permission-pull-requests: write/);
  assert.match(workflow, /GH_TOKEN: \$\{\{ steps\.release-app-token\.outputs\.token \}\}/);
  assert.match(workflow, /GH_TOKEN="\$\{\{ github\.token \}\}" gh workflow run commit-policy\.yml/);
  assert.match(workflow, /gh workflow run commit-policy\.yml/);
  assert.match(workflow, /--ref "\$\{branch\}"/);
  assert.match(workflow, /-f pull_number=/);
  assert.match(workflow, /-f head_sha=/);
  assert.match(workflow, /-f base_sha=/);
  assert.match(workflow, /-f base_ref=/);
});

test("fails when the release PR cannot be created", () => {
  assert.match(workflow, /## Release PR not created automatically[\s\S]*?exit 1/);
});

test("refreshes the PR number after creating or replacing a release PR", () => {
  assert.match(workflow, /if \[\[ -z "\$\{pr_number\}" \|\| "\$\{pr_state\}" != "OPEN" \]\]; then/);
  assert.match(workflow, /pr_number="\$\(gh pr view "\$\{branch\}" .* --json number --jq '\.number'\)"/);
});

test("replaces an existing workflow-authored release PR", () => {
  assert.match(workflow, /--json number,state,author/);
  assert.match(workflow, /pr_author="\$\(jq -r '\.author\.login \/\/ empty'/);
  assert.match(workflow, /"\$\{pr_state\}" == "OPEN" && "\$\{pr_author\}" == "github-actions\[bot\]"/);
  assert.match(workflow, /gh pr close "\$\{pr_number\}"/);
});
