import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { configSnippet } from "./models.js";

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, "..", "index.html"), "utf8");
const js = readFileSync(join(here, "models.js"), "utf8");

test("Models Discover has a catalog refresh control", function () {
  assert.match(html, /id="models-catalog-refresh"/);
  assert.match(html, />Refresh catalog</);
});

test("configSnippet writes a provider table from the catalog mapping", function () {
  const text = configSnippet({
    provider: "deepseek",
    id: "deepseek-chat",
    kind: "openai_compat",
    auth: "api_key",
    base_url: "https://api.deepseek.com",
    api_key_env: "DEEPSEEK_API_KEY",
    context: 65536,
    output: 8192,
  }, [], true);
  assert.match(text, /\[providers\.deepseek\]/);
  assert.match(text, /kind = "openai_compat"/);
  assert.match(text, /base_url = "https:\/\/api\.deepseek\.com"/);
  assert.match(text, /api_key_env = "DEEPSEEK_API_KEY"/);
  assert.doesNotMatch(text, /auth = /);
  assert.match(text, /\[models\."deepseek\/deepseek-chat"\]/);
});

test("Models edit form has an rpm field", function () {
  assert.match(html, /id="models-edit-rpm"/);
  assert.match(js, /payload\.rpm = rpm/);
});

test("Models edit form has a wire id field for aliases", function () {
  assert.match(html, /id="models-edit-id"/);
  assert.match(js, /payload\.id = sku/);
});

test("catalog refresh posts to /api/catalog/refresh", function () {
  assert.match(js, /function refreshCatalog\(/);
  assert.match(js, /\/api\/catalog\/refresh/);
  assert.match(js, /method:\s*"POST"/);
  assert.match(js, /getElementById\("models-catalog-refresh"\)[\s\S]*refreshCatalog/);
});

test("Configured table folds alias variants behind a group toggle", function () {
  assert.match(js, /models-group-toggle/);
  assert.match(js, /data-group/);
  assert.match(js, /variants\.length > 1/);
});
