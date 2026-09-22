"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const workflow = readFileSync(resolve(__dirname, "../workflows/verify.yml"), "utf8");
const readme = readFileSync(resolve(__dirname, "../../README.md"), "utf8");

test("CRAP reports are uploaded even when the ratchet fails", () => {
  assert.match(workflow, /name: Upload CRAP reports\n\s+if: always\(\)/);
  assert.match(workflow, /tools\/crap\/run\.sh/);
  assert.match(workflow, /--base-baseline/);
});

test("badge publication is limited to successful develop pushes or manual runs", () => {
  assert.match(workflow, /publish-crap-badge:[\s\S]*github\.event_name == 'workflow_dispatch'[\s\S]*refs\/heads\/develop/);
  assert.match(workflow, /needs: smoke/);
  assert.match(workflow, /pages: write/);
  assert.match(workflow, /id-token: write/);
  assert.match(workflow, /cp crap-reports\/badge\.json pages\/crap-badge\.json/);
});

test("README uses the public Shields endpoint and links Verify", () => {
  assert.match(readme, /img\.shields\.io\/endpoint\?url=https%3A%2F%2Fantonillos\.github\.io%2Fmakevn%2Fcrap-badge\.json/);
  assert.match(readme, /actions\/workflows\/verify\.yml/);
});
