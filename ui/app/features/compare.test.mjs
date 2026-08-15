import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "compare.js"), "utf8");

test("a failed comparison open replaces the answers, not just the status line", function () {
  assert.match(js, /showLoadError\(byId\("compare-answers"\)/);
  assert.match(js, /fetchComparison\(id\)/);
  const fail = js.slice(js.indexOf("Could not load comparison:"));
  assert.match(fail, /compare-answers/);
  assert.doesNotMatch(fail.slice(0, 400), /return null;\s*\}\);\s*\}\s*\nfunction renderComparison/);
});
