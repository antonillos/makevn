"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync, readdirSync } = require("node:fs");
const { resolve } = require("node:path");

const workflowsDir = resolve(__dirname, "../workflows");
const workflows = readdirSync(workflowsDir)
  .filter((name) => name.endsWith(".yml") || name.endsWith(".yaml"))
  .map((name) => ({
    name,
    source: readFileSync(resolve(workflowsDir, name), "utf8"),
  }));

test("pins every external action to a full commit SHA", () => {
  for (const { name, source } of workflows) {
    for (const match of source.matchAll(/^\s*-?\s*uses:\s*([^\s#]+)/gm)) {
      const action = match[1];
      if (action.startsWith("./")) continue;
      assert.match(action, /^[^@]+@[0-9a-f]{40}$/, `${name}: ${action}`);
    }
  }
});

test("release publishing uses the release App instead of a legacy PAT", () => {
  for (const name of ["release.yml", "release-test.yml", "publish-package-managers.yml"]) {
    const source = workflows.find((workflow) => workflow.name === name).source;
    assert.match(source, /MAKEVN_RELEASE_APP_CLIENT_ID/);
    assert.match(source, /MAKEVN_RELEASE_APP_PRIVATE_KEY/);
    assert.doesNotMatch(source, /MAKEVN_RELEASE_TOKEN/);
  }
});

test("package-manager publishing scopes the App token to the three repositories", () => {
  for (const name of ["release.yml", "publish-package-managers.yml"]) {
    const source = workflows.find((workflow) => workflow.name === name).source;
    assert.match(source, /repositories: \|\n\s+makevn\n\s+homebrew-tap\n\s+asdf-makevn/);
    assert.match(source, /permission-contents: write/);
  }
});
