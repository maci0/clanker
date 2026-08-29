import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { configSnippet, modelsStatusId, liveSnippetModel } from "./models.js";

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
  assert.match(html, /Requests per minute/);
  assert.match(js, /payload\.rpm = rpm/);
});

test("Models edit form has a wire id field for aliases", function () {
  assert.match(html, /id="models-edit-id"/);
  assert.match(html, /API model id/);
  assert.match(js, /payload\.id = sku/);
});

test("Configured models expose an enabled checkbox that persists the full row", function () {
  assert.match(js, /function enabledCheckbox\(entry\)/);
  assert.match(js, /checkbox\.type = "checkbox"/);
  assert.match(js, /entry\.enabled = checkbox\.checked/);
  assert.match(js, /saveModelEntry\(entry/);
});

test("catalog Search stays disabled until the query is long enough", function () {
  assert.match(js, /function syncCatalogBtn/);
  assert.match(js, /tooShort = !q \|\| q\.value\.trim\(\)\.length < 2/);
  assert.match(js, /Try another name, or refresh the catalog/);
});

test("Models list and catalog failures offer to try again", function () {
  assert.match(js, /function failWithRetry/);
  assert.match(js, /failWithRetry\(box, "Could not load providers/);
  assert.match(js, /failWithRetry\(out, "Could not list/);
  assert.match(js, /failWithRetry\(out, "Catalog search failed/);
  assert.match(js, /failWithRetry\(out, "Catalog refresh failed/);
});

test("catalog refresh posts to /api/catalog/refresh", function () {
  assert.match(js, /function refreshCatalog\(/);
  assert.match(js, /\/api\/catalog\/refresh/);
  assert.match(js, /method:\s*"POST"/);
  assert.match(js, /getElementById\("models-catalog-refresh"\)[\s\S]*refreshCatalog/);
});

test("model save copy does not tell the operator to restart by hand", function () {
  assert.doesNotMatch(js, /Restart clanker serve for this to take effect/);
  assert.match(js, /The server reloads into it/);
});

test("model write and remove use a confirm dialog, not click-again", function () {
  assert.match(js, /function askConfirm/);
  assert.match(js, /mod\.uiConfirm/);
  assert.match(js, /from config.local.toml\? A model only declared/);
  assert.doesNotMatch(js, /Click again/);
  assert.doesNotMatch(js, /pendingRemove|pendingSave/);
});

test("configured empty state offers Add model instead of only config.toml", function () {
  assert.match(js, /No models configured yet\. Use Add model/);
  assert.match(js, /Providers are configured, but none list a model here/);
  assert.match(js, /start\.textContent = "Add model…"/);
  assert.doesNotMatch(js, /No providers configured\. Add \[providers\.<name>\] in config\.toml/);
});

test("Configured table folds alias variants behind a group toggle", function () {
  assert.match(js, /models-group-toggle/);
  assert.match(js, /data-group/);
  assert.match(js, /variants\.length > 1/);
});

test("each panel announces on its own status line", function () {
  assert.equal(modelsStatusId(), "models-status");
  assert.equal(modelsStatusId("live"), "models-live-status");
  assert.equal(modelsStatusId("catalog"), "models-catalog-status");
  // All three lines exist as polite live regions.
  assert.match(html, /id="models-status" role="status" aria-live="polite"/);
  assert.match(html, /id="models-live-status" role="status" aria-live="polite"/);
  assert.match(html, /id="models-catalog-status" role="status" aria-live="polite"/);
});

test("live and catalog failures overwrite their panel's status line", function () {
  // A failed listing must not leave the panel announcing its last success.
  assert.match(js, /status\("Could not list models: " \+ err\.message, "live"\)/);
  assert.match(js, /status\("Catalog search failed: " \+ err\.message, "catalog"\)/);
  assert.match(js, /status\("Catalog refresh failed: " \+ err\.message, "catalog"\)/);
});

test("a live row only offers a snippet once the output cap is a whole positive number", function () {
  const row = { id: "qwen3:8b", context: 32768 };
  // No cap, junk, zero, negative, fractional: nothing honest to offer.
  assert.equal(liveSnippetModel("ollama", row, ""), null);
  assert.equal(liveSnippetModel("ollama", row, "soon"), null);
  assert.equal(liveSnippetModel("ollama", row, "0"), null);
  assert.equal(liveSnippetModel("ollama", row, "-8"), null);
  assert.equal(liveSnippetModel("ollama", row, "8192.5"), null);
  const m = liveSnippetModel("ollama", row, "8192");
  assert.equal(m.provider, "ollama");
  assert.equal(m.id, "qwen3:8b");
  assert.equal(m.output, 8192);
  assert.equal(m.context, 32768);
  // A row without a context window stays without one rather than writing 0.
  assert.equal("context" in liveSnippetModel("ollama", { id: "x" }, "1024"), false);
});

test("the live snippet carries the operator's cap as max_tokens", function () {
  // The provider is one of the configured ones (the live select only lists
  // those), so the snippet is the models table alone with the cap in it.
  const text = configSnippet(liveSnippetModel("ollama", { id: "qwen3:8b", context: 32768 }, "8192"), ["ollama"], true);
  assert.doesNotMatch(text, /\[providers\./);
  assert.match(text, /\[models\."ollama\/qwen3:8b"\]/);
  assert.match(text, /max_tokens = 8192/);
  assert.match(text, /context_window = 32768/);
});

test("the live panel asks for the output cap and refuses without it", function () {
  assert.match(html, /id="models-live-cap"/);
  assert.match(js, /Set the output cap first/);
  assert.match(js, /reportValidity\(\)/);
});
