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

test("a room wider than the window pans inside the view instead of being cropped", () => {
  // The floor is 16 tiles (512px) and cannot scale, so it is wider than a
  // phone. Two things used to break that: `Math.max(360, ...)` set a width
  // floor above the container, so the canvas pushed the whole page sideways,
  // and rooms wrapped against that floor, so the first room -- which never fit
  // -- was drawn at x=pad with its right half outside the canvas and no way to
  // reach it. The canvas now sits in an overflow-x-auto panel and its width is
  // whatever the laid-out floor needs.
  const scroll = /\bSCROLL_CLASS = "([^"]*)"/.exec(js);
  assert.ok(scroll, "the scroll panel still states its classes");
  assert.match(scroll[1], /overflow-x-auto/);
  assert.match(js, /T\.div\(\{ class: SCROLL_CLASS[\s\S]*?canvas\)/);

  const from = js.indexOf("function draw()");
  const to = js.indexOf("ctx2d.clearRect", from);
  assert.ok(from >= 0 && to > from, "draw() is still there");
  // Comments carry the old spelling, so assert on the code alone.
  const body = js.slice(from, to)
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^\s*\/\/.*$/gm, "");
  // A pixel-count floor on the container width is what put the canvas wider
  // than the window; the 1 is the guard against a zero-width container, not a
  // floor, so only a floor of two digits or more is the regression.
  assert.doesNotMatch(body, /Math\.max\(\s*\d{2,}\s*,\s*container\.clientWidth/,
    "no pixel floor on the container width");
  assert.match(body, /canvas\.width = Math\.max\(1, maxW\)/,
    "the canvas is as wide as the floor is, not clamped to the window");
});

test("the canvas takes its colours from the page's tokens", () => {
  // Colour is the one thing a theme owns. The plugin ships no sheet any more:
  // its chrome is `bg-bg`/`border-rule` over the theme's var() chain, and the
  // floor it paints is drawn from `getPropertyValue` reads of those same
  // custom properties. The hex strings left in the file are the fallbacks an
  // empty read needs, which is not the same as a colour chosen here.
  const canvas = /\bCANVAS_CLASS = "([^"]*)"/.exec(js);
  assert.ok(canvas, "the canvas still states its classes");
  assert.match(canvas[1], /pixelated/);
  assert.match(canvas[1], /bg-bg/);
  assert.match(canvas[1], /border-rule/);
  assert.match(js, /getComputedStyle\(document\.documentElement\)/);
  assert.match(js, /cssVar\("--(border|surface-2|fg|fg-muted)"/);
});
