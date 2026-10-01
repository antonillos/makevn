"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/prepare-release.yml"), "utf8");
const releaseWorkflow = readFileSync(resolve(__dirname, "../workflows/release.yml"), "utf8");

test("uses a least-privilege GitHub App token for release PRs", () => {
  assert.match(workflow, /permissions:\n  contents: read/);
  assert.doesNotMatch(workflow, /permissions:[\s\S]*?actions: write/);
  assert.match(workflow, /uses: actions\/create-github-app-token@[0-9a-f]{40}/);
  assert.match(workflow, /client-id: \$\{\{ vars\.MAKEVN_RELEASE_APP_CLIENT_ID \}\}/);
  assert.match(workflow, /private-key: \$\{\{ secrets\.MAKEVN_RELEASE_APP_PRIVATE_KEY \}\}/);
  assert.match(workflow, /permission-contents: write/);
  assert.match(workflow, /permission-pull-requests: write/);
  assert.match(workflow, /GH_TOKEN: \$\{\{ steps\.release-app-token\.outputs\.token \}\}/);
  assert.match(workflow, /persist-credentials: false/);
  assert.match(workflow, /gh auth setup-git\n\s+git push --force-with-lease/);
  assert.ok(
    workflow.indexOf("Run smoke tests") < workflow.indexOf("id: release-app-token") &&
      workflow.indexOf("id: release-app-token") < workflow.indexOf("Create release branch"),
    "the App token must be minted after validation and before the branch push",
  );
  assert.doesNotMatch(workflow, /gh workflow run commit-policy\.yml/);
});

test("fails when the release PR cannot be created", () => {
  assert.match(workflow, /## Release PR not created automatically[\s\S]*?exit 1/);
});

test("replaces an existing workflow-authored release PR", () => {
  assert.match(workflow, /--json number,state,author,title,body/);
  assert.match(workflow, /pr_author="\$\(jq -r '\.author\.login \/\/ empty'/);
  assert.match(workflow, /"\$\{pr_state\}" == "OPEN" && "\$\{pr_author\}" == "github-actions\[bot\]"/);
  assert.match(workflow, /gh pr close "\$\{pr_number\}"/);
});

test("does not emit a redundant edited event for unchanged release PR metadata", () => {
  assert.match(workflow, /if \[\[ "\$\{pr_title\}" != "\$\{title\}" \|\| "\$\{pr_body\}" != "\$\{body\}" \]\]; then/);
});

test("push-triggered releases retain prerelease status from the version suffix", () => {
  assert.match(releaseWorkflow, /prerelease="\$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.prerelease \|\| false \}\}"/);
  assert.match(releaseWorkflow, /if \[\[ "\$\{\{ github\.event_name \}\}" == push && "\$SEMVER" == \*-\* \]\]; then\s+prerelease=true/);
  assert.match(releaseWorkflow, /printf 'prerelease=%s\\n' "\$prerelease" >> "\$GITHUB_OUTPUT"/);
});


test("release notes use generated changes and full tag history", () => {
  const createRelease = releaseWorkflow.slice(releaseWorkflow.indexOf("  create-release:"));
  assert.match(createRelease, /fetch-depth: 0/);
  assert.match(createRelease, /python3 packaging\/release\/render-notes\.py/);
  assert.match(createRelease, /--repository "\$REPOSITORY" --target "\$TARGET_REF" --output release-notes\.md/);
  assert.ok(createRelease.indexOf("id: release-app-token") < createRelease.indexOf("name: Generate release notes"));
  assert.ok(createRelease.indexOf("name: Generate release notes") < createRelease.indexOf("name: Create GitHub release"));
  assert.doesNotMatch(createRelease, /brew install|asdf plugin add|curl -fsSL/);
});
