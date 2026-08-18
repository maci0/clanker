// Drives the shipped settings-field typing rule. A config_editable key with
// no value yet used to be typed "undefined" off `typeof current` and saved
// back as a string; the descriptor's declared type (config_types) must win.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, "tools.js"), "utf8");

function loadConfigFieldKind() {
  const m = /export function configFieldKind\(t, key, current\) \{([\s\S]*?)\n\}/.exec(src);
  assert.ok(m, "configFieldKind missing from tools.js");
  return new Function("t", "key", "current", m[1]);
}

test("declared type wins over a value that is not there yet", function () {
  const kind = loadConfigFieldKind();
  const t = { config_types: { max_depth: "number", loud: "boolean", label: "string" } };
  assert.equal(kind(t, "max_depth", undefined), "number");
  assert.equal(kind(t, "loud", undefined), "boolean");
  assert.equal(kind(t, "label", undefined), "string");
});

test("declared type wins over an override saved with the wrong type", function () {
  const kind = loadConfigFieldKind();
  const t = { config_types: { max_depth: "number" } };
  // A hand-edited state/plugin_config.json can hold "9" where 9 belongs;
  // the field must stay numeric so the next save heals the type.
  assert.equal(kind(t, "max_depth", "9"), "number");
});

test("typeof current stays the fallback when nothing is declared", function () {
  const kind = loadConfigFieldKind();
  assert.equal(kind({}, "max_depth", 3), "number");
  assert.equal(kind({}, "loud", false), "boolean");
  assert.equal(kind({}, "label", "hi"), "string");
  assert.equal(kind({}, "ghost", undefined), "undefined");
  // An unknown declared name never reaches the save path's switch.
  assert.equal(kind({ config_types: { shape: "object" } }, "shape", 3), "number");
});

test("buildToolConfig types its inputs through configFieldKind", function () {
  assert.match(src, /var kind = configFieldKind\(t, key, current\)/);
  assert.match(src, /input\.type = kind === "number" \? "number" : "text"/);
  assert.match(src, /input\.dataset\.kind = kind/);
  // The old rule is gone: nothing types a field off typeof current directly.
  assert.doesNotMatch(src, /input\.dataset\.kind = typeof current/);
});
