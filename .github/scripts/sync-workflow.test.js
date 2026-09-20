"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/sync-main-to-develop.yml"), "utf8");

test("syncs every main push and successful release completion", () => {
  assert.match(workflow, /permissions:\n  contents: read/);
  assert.doesNotMatch(workflow, /permissions:[\s\S]*?actions: write/);
  assert.match(workflow, /uses: actions\/create-github-app-token@[0-9a-f]{40}/);
  assert.match(workflow, /client-id: \$\{\{ vars\.MAKEVN_RELEASE_APP_CLIENT_ID \}\}/);
  assert.match(workflow, /private-key: \$\{\{ secrets\.MAKEVN_RELEASE_APP_PRIVATE_KEY \}\}/);
  assert.match(workflow, /permission-contents: write/);
  assert.match(workflow, /permission-pull-requests: write/);
  assert.match(workflow, /GH_TOKEN: \$\{\{ steps\.release-app-token\.outputs\.token \}\}/);
  assert.match(workflow, /token: \$\{\{ steps\.release-app-token\.outputs\.token \}\}/);
  assert.ok(
    workflow.indexOf("id: release-app-token") < workflow.indexOf("uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"),
    "the App token must authenticate checkout and branch pushes",
  );
  assert.match(workflow, /push:\n    branches:\n      - main/);
  assert.match(workflow, /workflow_run:\n    workflows:\n      - Release/);
  assert.match(workflow, /github\.event_name == 'push'/);
  assert.match(workflow, /github\.event\.workflow_run\.conclusion == 'success'/);
  assert.doesNotMatch(workflow, /gh workflow run commit-policy\.yml/);
});

test("fails when the sync PR cannot be created", () => {
  assert.match(workflow, /## Sync PR not created automatically[\s\S]*?exit 1/);
});

test("creates and pushes a signed merge even when the tree is unchanged", () => {
  assert.match(workflow, /--no-ff/);
  assert.match(workflow, /--gpg-sign/);
  assert.match(workflow, /git cat-file commit HEAD \| grep -q '\^gpgsig '/);
  assert.match(workflow, /git push --force-with-lease origin/);
  assert.doesNotMatch(workflow, /git diff --quiet origin\/develop HEAD/);
});

test("replaces an existing workflow-authored sync PR", () => {
  assert.match(workflow, /--json number,author,title,body/);
  assert.match(workflow, /pr_author="\$\(jq -r '\.author\.login \/\/ empty'/);
  assert.match(workflow, /if \[\[ "\$\{pr_author\}" == "github-actions\[bot\]" \]\]; then/);
  assert.match(workflow, /gh pr close "\$\{pr_number\}"/);
});

test("does not emit a redundant edited event for unchanged sync PR metadata", () => {
  assert.match(workflow, /if \[\[ "\$\{pr_title\}" != "\$\{title\}" \|\| "\$\{pr_body\}" != "\$\{body\}" \]\]; then/);
});
