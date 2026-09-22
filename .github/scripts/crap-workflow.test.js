"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/verify.yml"), "utf8");
const readme = readFileSync(resolve(__dirname, "../../README.md"), "utf8");

test("CRAP reports are uploaded even when the ratchet fails", () => {
  const smoke = workflow.slice(workflow.indexOf("  smoke:"), workflow.indexOf("  crap:"));
  const crap = workflow.slice(workflow.indexOf("  crap:"), workflow.indexOf("  publish-crap-badge:"));

  assert.doesNotMatch(smoke, /Run CRAP|tools\/crap\/run\.sh|Install CRAP analysis tools/);
  assert.match(crap, /name: Upload CRAP reports\n\s+if: always\(\)/);
  assert.match(crap, /tools\/crap\/run\.sh/);
  assert.match(crap, /--base-baseline/);
  assert.match(workflow, /base_ref:[\s\S]*CRAP_BASE_REF:/);
  assert.match(crap, /\[\[ -f "\$\{RUNNER_TEMP\}\/crap-base-baseline\.json" \]\]/);
});

test("badge publication is limited to successful develop pushes or manual runs", () => {
  assert.match(workflow, /publish-crap-badge:[\s\S]*github\.event_name == 'workflow_dispatch' && inputs\.publish_badge[\s\S]*refs\/heads\/develop/);
  assert.match(workflow, /needs: crap/);
  assert.match(workflow, /pages: write/);
  assert.match(workflow, /id-token: write/);
  assert.match(workflow, /cp crap-reports\/badge\.json pages\/crap-badge\.json/);
});

test("README uses the public Shields endpoint and links Verify", () => {
  assert.match(readme, /img\.shields\.io\/endpoint\?url=https%3A%2F%2Fantonillos\.github\.io%2Fmakevn%2Fcrap-badge\.json/);
  assert.match(readme, /actions\/workflows\/verify\.yml/);
});
