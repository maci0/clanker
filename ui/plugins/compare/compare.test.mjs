import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "app.js"), "utf8");
const spec = readFileSync(join(dir, "plugin.json"), "utf8");

test("Compare is a Watch plugin that confirms before recording a pick", function () {
  assert.match(spec, /"name": "compare"/);
  assert.match(spec, /"group": "Watch"/);
  assert.match(js, /clanker\.registerView/);
  assert.match(js, /api\.confirm\("Pick answer " \+ a\.label \+ "\? You cannot change this later\."/);
  assert.match(js, /if \(yes\) recordPick/);
  assert.match(js, /No comparisons yet\. Run one with /);
  assert.match(js, /Try again/);
});

test("a failed comparison open replaces the answers, not just the status line", function () {
  assert.match(js, /showError\(answers, msg/);
  assert.match(js, /fetchComparison\(id\)/);
  const fail = js.slice(js.indexOf("Could not load comparison:"));
  assert.match(fail, /showError\(answers/);
  assert.doesNotMatch(fail.slice(0, 400), /return null;\s*\}\);\s*\}\s*\nfunction renderComparison/);
});
