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
