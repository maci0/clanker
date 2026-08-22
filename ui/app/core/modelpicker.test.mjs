// Coding-agent backends belong in their own picker group, not among
// API-key provider rows. These tests drive the shipped index builder.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { pickerIndexFromPayload, runOptionsFromValue } from "./modelpicker.js";

const here = dirname(fileURLToPath(import.meta.url));

test("installed coding-agent backends sit in a local-CLI group, not an API-key provider row", function () {
  const index = pickerIndexFromPayload({
    providers: [
      { name: "deepseek", usable: true, models: [{ name: "deepseek-chat", display: "DeepSeek" }] },
    ],
    backends: [
      { name: "grok", group: "Local coding-agent backend", kind: "coding-agent" },
    ],
  });
  assert.equal(index[0].backend, "grok");
  assert.equal(index[0].provider, "Local coding-agent backend");
  assert.equal(index[0].value, "backend:grok");
  assert.equal(index[1].provider, "deepseek");
  assert.equal(index[1].backend, undefined);
  assert.notEqual(index[1].value.slice(0, 8), "backend:");
});

test("choosing a backend row is what POST /api/run sends as backend", function () {
  assert.deepEqual(runOptionsFromValue("backend:grok"), { backend: "grok" });
  assert.deepEqual(runOptionsFromValue("deepseek deepseek-chat"), {
    provider: "deepseek",
    model: "deepseek-chat",
  });
});

test("disabled configured models stay out of the picker", function () {
  const index = pickerIndexFromPayload({
    providers: [{
      name: "anthropic",
      usable: true,
      models: [
        { name: "claude-opus", enabled: true },
        { name: "claude-haiku", enabled: false },
        // Older servers omit the field; those models remain visible.
        { name: "claude-sonnet" },
      ],
    }],
  });
  assert.deepEqual(index.map(function (row) { return row.model; }), ["claude-opus", "claude-sonnet"]);
});

test("the shipped picker and chat POST still name the backend field", function () {
  const picker = readFileSync(join(here, "modelpicker.js"), "utf8");
  assert.match(picker, /Local coding-agent backend/);
  assert.match(picker, /backend:/);
  const app = readFileSync(join(here, "..", "app.js"), "utf8");
  assert.match(app, /backend: opts\.backend/);
});
