"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/sync-main-to-develop.yml"), "utf8");

test("syncs every main push and successful release completion", () => {
  assert.match(workflow, /push:\n    branches:\n      - main/);
  assert.match(workflow, /workflow_run:\n    workflows:\n      - Release/);
  assert.match(workflow, /github\.event_name == 'push'/);
  assert.match(workflow, /github\.event\.workflow_run\.conclusion == 'success'/);
});

test("creates and pushes a signed merge even when the tree is unchanged", () => {
  assert.match(workflow, /--no-ff/);
  assert.match(workflow, /--gpg-sign/);
  assert.match(workflow, /git cat-file commit HEAD \| grep -q '\^gpgsig '/);
  assert.match(workflow, /git push --force-with-lease origin/);
  assert.doesNotMatch(workflow, /git diff --quiet origin\/develop HEAD/);
});
