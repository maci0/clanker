// The model and reasoning-effort selects used to write two browser-global
// keys, so picking a model in one conversation changed what every other
// conversation and every other tab sent next. These tests pin the per-chat
// store that replaced them: one entry per session id, bounded the way the
// draft store is, and a browser default that only a chat with no pin follows.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  prefsFor, setPref, dropPref, copyPref, max_prefs,
  effectiveModel, effectiveEffort,
} from "./chatprefs.js";

test("a pin belongs to the conversation it was set in", function () {
  const prefs = {};
  setPref(prefs, "sess-a", { model: "openai gpt-5" }, 1);
  setPref(prefs, "sess-b", { model: "anthropic claude-opus-5" }, 2);
  assert.equal(prefsFor(prefs, "sess-a").model, "openai gpt-5");
  assert.equal(prefsFor(prefs, "sess-b").model, "anthropic claude-opus-5");
});

test("a conversation with no pin has none — the caller falls back to the default", function () {
  const prefs = {};
  setPref(prefs, "sess-a", { model: "openai gpt-5" }, 1);
  assert.equal(prefsFor(prefs, "sess-untouched"), null);
  assert.equal(prefsFor(prefs, ""), null);
  assert.equal(prefsFor(null, "sess-a"), null);
});

test("model and effort are pinned independently, and a later patch merges", function () {
  const prefs = {};
  setPref(prefs, "sess-a", { model: "openai gpt-5" }, 1);
  setPref(prefs, "sess-a", { effort: "high" }, 2);
  assert.deepEqual(
    { model: prefsFor(prefs, "sess-a").model, effort: prefsFor(prefs, "sess-a").effort },
    { model: "openai gpt-5", effort: "high" },
  );
});

test("clearing a field unpins only that field; clearing both drops the entry", function () {
  const prefs = {};
  setPref(prefs, "sess-a", { model: "openai gpt-5", effort: "high" }, 1);
  setPref(prefs, "sess-a", { effort: "" }, 2);
  assert.equal(prefsFor(prefs, "sess-a").effort, undefined);
  assert.equal(prefsFor(prefs, "sess-a").model, "openai gpt-5");
  setPref(prefs, "sess-a", { model: "" }, 3);
  assert.equal(prefsFor(prefs, "sess-a"), null);
});

test("the store is bounded like the draft store, oldest touched dropped first", function () {
  const prefs = {};
  for (let i = 0; i < max_prefs + 5; i++) setPref(prefs, "sess-" + i, { model: "m" + i }, i + 1);
  assert.equal(Object.keys(prefs).length, max_prefs);
  assert.equal(prefsFor(prefs, "sess-0"), null, "the oldest pin is the one evicted");
  assert.ok(prefsFor(prefs, "sess-" + (max_prefs + 4)), "the newest pin survives");
});

test("deleting a conversation takes its pin with it", function () {
  const prefs = {};
  setPref(prefs, "sess-a", { model: "openai gpt-5" }, 1);
  dropPref(prefs, "sess-a");
  assert.equal(prefsFor(prefs, "sess-a"), null);
});

test("a fork carries the pin onto the new id and leaves the original's alone", function () {
  const prefs = {};
  setPref(prefs, "sess-a", { model: "openai gpt-5", effort: "high" }, 1);
  copyPref(prefs, "sess-a", "sess-fork", 2);
  assert.equal(prefsFor(prefs, "sess-fork").model, "openai gpt-5");
  assert.equal(prefsFor(prefs, "sess-fork").effort, "high");
  assert.equal(prefsFor(prefs, "sess-a").model, "openai gpt-5");
  // Later edits to the copy do not reach back into the conversation it came from.
  setPref(prefs, "sess-fork", { model: "anthropic claude-opus-5" }, 3);
  assert.equal(prefsFor(prefs, "sess-a").model, "openai gpt-5");
});

test("copying from a conversation with no pin pins nothing", function () {
  const prefs = {};
  copyPref(prefs, "sess-none", "sess-fork", 1);
  assert.equal(prefsFor(prefs, "sess-fork"), null);
});

test("a pinned conversation ignores the browser default", function () {
  const prefs = {};
  setPref(prefs, "sess-a", { model: "openai gpt-5", effort: "high" }, 1);
  const pin = prefsFor(prefs, "sess-a");
  assert.equal(effectiveModel(pin, "anthropic claude-opus-5"), "openai gpt-5");
  assert.equal(effectiveEffort(pin, "low"), "high");
});

test("an unpinned conversation follows the browser default", function () {
  const pin = prefsFor({}, "sess-new");
  assert.equal(effectiveModel(pin, "anthropic claude-opus-5"), "anthropic claude-opus-5");
  assert.equal(effectiveEffort(pin, "low"), "low");
  // Neither pinned nor defaulted is the config default, not a blank select.
  assert.equal(effectiveModel(null, ""), "");
  assert.equal(effectiveEffort(null, null), "");
});

test("a half-pinned conversation takes the default for the other field only", function () {
  const prefs = {};
  setPref(prefs, "sess-a", { effort: "max" }, 1);
  const pin = prefsFor(prefs, "sess-a");
  assert.equal(effectiveModel(pin, "openai gpt-5"), "openai gpt-5");
  assert.equal(effectiveEffort(pin, "low"), "max");
});

/* The store above is only worth having if the composer actually reads and
   writes it. These read the shipped sources: a picker that still wrote only
   the two browser-global keys, or an app that never put a conversation's pin
   back on switching, would pass every test above and change nothing. */
const here = dirname(fileURLToPath(import.meta.url));
const picker = readFileSync(join(here, "modelpicker.js"), "utf8");
const app = readFileSync(join(here, "..", "app.js"), "utf8");

test("every model/effort write in the picker records the conversation's pin", function () {
  // Both paths that change the model: the popover's own click and the hidden
  // select's change event.
  assert.equal((picker.match(/pinChat\(\{ model:/g) || []).length, 2);
  assert.equal((picker.match(/pinChat\(\{ effort:/g) || []).length, 1);
  // Nothing writes a bare global key any more; the two defaults go through
  // writeDefault, beside the pin.
  assert.equal(picker.indexOf('setItem("clanker.model"'), -1);
  assert.equal(picker.indexOf('setItem("clanker.effort"'), -1);
});

test("the picker restores from the pin, not from the browser default alone", function () {
  assert.ok(/var saved = effectiveModel\(\);/.test(picker));
  assert.ok(/var savedEffort = effectiveEffort\(\);/.test(picker));
});

test("app.js hands the picker this conversation's pin and moves it with the session", function () {
  assert.ok(/chatPrefs: \{ get: chatPrefsGet, set: chatPrefsSet \}/.test(app), "hooks are bound");
  // Switching conversation, starting one, and deleting one all put the right
  // values back on the shared selects.
  assert.ok((app.match(/\bapplyChatPrefs\(\);/g) || []).length >= 3);
  assert.ok(/chatPrefsDrop\(sessionId\);/.test(app), "a deleted conversation drops its pin");
  assert.ok(/chatPrefsCarry\(sessionId, newId\)/.test(app), "a fork carries the pin");
  assert.ok(/chatPrefsPinFirstTurn\(\);/.test(app), "the first turn pins what it ran on");
});
