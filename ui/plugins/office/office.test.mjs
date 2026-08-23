// The office view's first suite. It exists for one defect and stays for the
// plugin rules the view has to keep.
//
// `api.storage` swallows a blocked store (`ui/app/core/plugins.js`); a bare
// `localStorage` does not. Reading the property throws `SecurityError` when a
// browser is set to block site data, and the pre-migration alarm key was read
// bare on the first line of `mount` — so an optional preference read replaced
// the whole view with the plugin error panel in a browser where nothing about
// the office needs storage at all. Music does the same migration read inside a
// `try`, which is the shape.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "app.js"), "utf8");
const css = readFileSync(join(dir, "app.css"), "utf8");
const manifest = JSON.parse(readFileSync(join(dir, "plugin.json"), "utf8"));

test("no bare localStorage read can take the whole view down", () => {
  const hits = [...js.matchAll(/localStorage\s*\./g)].map((m) => m.index);
  assert.equal(hits.length, 1, "one pre-migration read, and it must be guarded");
  const from = js.indexOf("function legacyAlarm()");
  assert.ok(from >= 0, "the guarded reader is still there");
  const to = js.indexOf("var alarmOn", from);
  assert.ok(to > from);
  assert.ok(hits[0] > from && hits[0] < to, "the only localStorage read is inside legacyAlarm");
  assert.match(js.slice(from, to), /try \{[\s\S]*localStorage[\s\S]*\} catch/);
  // api.storage is the supported path and is already guarded host-side.
  assert.match(js, /api\.storage\.get\("alarm"\)/);
});

test("legacyAlarm answers false where reading the store throws", () => {
  // Not a text match: the shipped function is lifted out and run against a
  // `window` whose `localStorage` property getter raises, which is what Safari
  // with "Block All Cookies" does. Before the guard this threw straight out of
  // `mount`.
  const from = js.indexOf("function legacyAlarm()");
  const to = js.indexOf("var alarmOn", from);
  const win = {};
  Object.defineProperty(win, "localStorage", {
    get() { const e = new Error("The operation is insecure."); e.name = "SecurityError"; throw e; },
  });
  const ctx = { window: win };
  vm.createContext(ctx);
  vm.runInContext(js.slice(from, to) + "\nvar out = legacyAlarm();", ctx);
  assert.equal(ctx.out, false);

  // And it still reads a real value when the store is there.
  const ok = { window: { localStorage: { getItem: (k) => (k === "clanker-office-alarm" ? "on" : null) } } };
  vm.createContext(ok);
  vm.runInContext(js.slice(from, to) + "\nvar out = legacyAlarm();", ok);
  assert.equal(ok.out, true);
});

test("office is a Watch plugin that draws without innerHTML or eval", () => {
  assert.equal(manifest.name, "office");
  assert.equal(manifest.group, "Watch");
  assert.doesNotMatch(js, /innerHTML/);
  assert.doesNotMatch(js, /\beval\(/);
});

test("the frame loop and the polls idle on a hidden view", () => {
  // The host never unmounts a view, it only toggles `hidden` on the `.view`
  // panel, so every timer has to ask the panel whether anyone is looking.
  assert.match(js, /container\.closest\(".view"\)/);
  assert.doesNotMatch(js, /container\.hidden/);
});

test("the canvas takes its colours from the page's tokens", () => {
  // Colour is the one thing a theme owns; a literal here is the one thing on
  // the page that would not follow it.
  assert.doesNotMatch(css, /#[0-9a-fA-F]{3,8}\b/);
  assert.match(css, /var\(--/);
});
