"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/prepare-release.yml"), "utf8");

test("uses a least-privilege GitHub App token for release PRs", () => {
  assert.match(workflow, /uses: actions\/create-github-app-token@v3/);
  assert.match(workflow, /client-id: \$\{\{ vars\.MAKEVN_RELEASE_APP_CLIENT_ID \}\}/);
  assert.match(workflow, /private-key: \$\{\{ secrets\.MAKEVN_RELEASE_APP_PRIVATE_KEY \}\}/);
  assert.match(workflow, /permission-contents: write/);
  assert.match(workflow, /permission-pull-requests: write/);
  assert.match(workflow, /GH_TOKEN: \$\{\{ steps\.release-app-token\.outputs\.token \}\}/);
  assert.match(workflow, /token: \$\{\{ steps\.release-app-token\.outputs\.token \}\}/);
  assert.ok(
    workflow.indexOf("id: release-app-token") < workflow.indexOf("uses: actions/checkout@v7"),
    "the App token must authenticate checkout and branch pushes",
  );
  assert.doesNotMatch(workflow, /gh workflow run commit-policy\.yml/);
});

test("fails when the release PR cannot be created", () => {
  assert.match(workflow, /## Release PR not created automatically[\s\S]*?exit 1/);
});

test("replaces an existing workflow-authored release PR", () => {
  assert.match(workflow, /--json number,state,author/);
  assert.match(workflow, /pr_author="\$\(jq -r '\.author\.login \/\/ empty'/);
  assert.match(workflow, /"\$\{pr_state\}" == "OPEN" && "\$\{pr_author\}" == "github-actions\[bot\]"/);
  assert.match(workflow, /gh pr close "\$\{pr_number\}"/);
});
