import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "app.js"), "utf8");
const spec = readFileSync(join(dir, "plugin.json"), "utf8");

test("Search is a Work plugin that searches conversations", function () {
  assert.match(spec, /"name": "search"/);
  assert.match(spec, /"group": "Work"/);
  assert.match(js, /clanker\.registerView/);
  assert.match(js, /setAttribute\("for", "search-q"\)/);
  assert.match(js, /Search conversations/);
  assert.match(js, /btn\.disabled = on \|\| tooShort/);
  assert.match(js, /Type at least /);
  assert.match(js, /Try again/);
  assert.match(js, /api\.openSession/);
});
