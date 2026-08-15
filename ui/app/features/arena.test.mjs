import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "arena.js"), "utf8");

test("a failed match open replaces the transcript, not just the status line", function () {
  assert.match(js, /showLoadError\(byId\("arena-transcript"\)/);
  assert.match(js, /fetchMatch\(id, false\)/);
  const fail = js.slice(js.indexOf("Could not load match:"));
  assert.match(fail, /arena-transcript/);
});
