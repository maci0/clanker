import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, "..", "index.html"), "utf8");
const js = readFileSync(join(here, "models.js"), "utf8");

test("Models Discover has a catalog refresh control", function () {
  assert.match(html, /id="models-catalog-refresh"/);
  assert.match(html, />Refresh catalog</);
});

test("catalog refresh posts to /api/catalog/refresh", function () {
  assert.match(js, /function refreshCatalog\(/);
  assert.match(js, /\/api\/catalog\/refresh/);
  assert.match(js, /method:\s*"POST"/);
  assert.match(js, /getElementById\("models-catalog-refresh"\)[\s\S]*refreshCatalog/);
});
