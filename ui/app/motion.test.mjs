// Reduced motion is a setting, not a decoration: every animation, transition
// and smooth scroll has to answer `prefers-reduced-motion: reduce`. Two things
// broke it silently and are pinned here.
//
// A cascade layer outranks an earlier rule of equal specificity wherever the
// two sit in the file, so a `@media (prefers-reduced-motion: reduce)` block in
// `@layer base` lost to the component rule it corrected: the toast slid in, the
// turn lamps breathed and the skip link dropped in for a reader who asked for
// none of it. The fix is one unlayered guard at the end of the sheet, which
// outranks every layer, so this reads the compiled sheet to confirm the winning
// rule is the unlayered one rather than trusting the source order.
//
// Smooth `scrollIntoView` is motion too, and the call sites live in feature
// views that each shipped the literal "smooth".
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const src = readFileSync(join(here, "tailwind.src.css"), "utf8");

/* The cascade order under test is the compiled sheet's, and the committed
   `tailwind.css` is a clean rebuild of the source: `ui/app/verify-css.sh`
   diffs a fresh `bun run css:build` against it in CI and in the gate, so a
   stale output is a red check there rather than a wrong answer here. Reading
   the committed file keeps this suite to the millisecond. */
const compiled = readFileSync(join(here, "tailwind.css"), "utf8");

// Layer ordering is the whole defect, and it is settled in the source sheet:
// the guard opens no layer (the first test), and the compiled sheet has to put
// it after every declaration it answers for. A guard that lost that ordering is
// the bug, whatever layer each side sits in.

// A rule inside a `prefers-reduced-motion` block is its own answer, in either
// direction, so the scan for rules that need one skips those spans.
function outsideMotionBlocks(css) {
  let out = css;
  for (;;) {
    const at = out.indexOf("@media (prefers-reduced-motion");
    if (at < 0) return out;
    const open = out.indexOf("{", at);
    let depth = 0;
    let close = -1;
    for (let i = open; i < out.length; i++) {
      if (out[i] === "{") depth++;
      else if (out[i] === "}" && --depth === 0) { close = i + 1; break; }
    }
    if (close < 0) return out.slice(0, at);
    out = out.slice(0, at) + out.slice(close);
  }
}

test("the reduced-motion guard in the source sheet opens no layer", function () {
  const guard = src.lastIndexOf("@media (prefers-reduced-motion: reduce) {");
  assert.ok(guard > 0, "no reduce guard in tailwind.src.css");
  assert.ok(!src.slice(guard).includes("@layer"), "the reduce guard opens a layer, which re-defeats it");
});

test("toast, turn lamps and skip link stop animating when motion is reduced", function () {
  const css = compiled;
  const animated = ["animation: toast-in", "animation: lamp-breathe", "animation: lamp-steady",
    "transition: top 0.15s"];
  for (const needle of animated) {
    assert.ok(css.includes(needle), needle + " is missing from the compiled sheet");
  }
  // The guard that names every moving selector is the last word on all of them.
  const guards = [];
  let at = css.indexOf("@media (prefers-reduced-motion: reduce) {");
  while (at >= 0) {
    guards.push(at);
    at = css.indexOf("@media (prefers-reduced-motion: reduce) {", at + 1);
  }
  const named = guards.filter(function (at2) {
    return css.slice(at2, at2 + 700).includes(".turn[data-phase=\"llm\"]::before");
  });
  assert.equal(named.length, 1, "want exactly one guard naming the turn lamps, got " + named.length);
  assert.ok(named[0] > Math.max.apply(null, animated.map(function (n) { return css.indexOf(n); })),
    "the guard must come after every animated rule");
  const block = css.slice(named[0]);
  for (const selector of [".toast", ".skip-link", '.turn[data-phase="ask"]::before',
    '.turn[data-phase="llm"]::before', ".code-block .copy-code-btn",
    ".rail-fold > summary.rail-group::after", ".disclosure-caret > summary::before",
    "#board-grid"]) {
    assert.ok(block.includes(selector), "the unlayered reduce guard misses " + selector);
  }
});

test("every rule that moves something is named by the reduce guard", function () {
  // The sheet's whole contract is one unlayered guard naming each moving rule.
  // A new animation or transition added without a guard is a diff that has to
  // extend this list, and this is what says so out loud.
  const block = src.slice(src.lastIndexOf("@media (prefers-reduced-motion: reduce) {"));
  const sheet = outsideMotionBlocks(src);
  const moving = sheet.match(/[^{}]*\{[^{}]*\b(?:animation|transition|scroll-behavior)\s*:[^;{}]*[^{}]*\}/g) || [];
  const guarded = new Set();
  for (const selector of block.matchAll(/[^{}]*\{/g)) {
    for (const name of selector[0].split(",")) {
      const clean = name.replace(/\s+/g, " ").trim();
      if (clean) guarded.add(clean);
    }
  }
  // `.lit[data-state="running"]` answers the setting at the property instead,
  // under `@media (prefers-reduced-motion: no-preference)`.
  const noPreference = /@media \(prefers-reduced-motion: no-preference\) \{[^}]*\.lit\[data-state="running"\]/;
  assert.match(src, noPreference, "the running lamp lost its no-preference guard");
  for (const rule of moving) {
    const selector = rule.split("{")[0].replace(/\s+/g, " ").trim();
    if (selector.includes("prefers-reduced-motion")) continue;
    if (guarded.has(selector)) continue;
    // A compound selector is guarded by any single part of it.
    const covered = selector.split(/[\s,>]+/).some(function (part) {
      return [...guarded].some(function (g) { return g.split(/[\s,>]+/).includes(part); });
    });
    assert.ok(covered, "no reduced-motion answer for: " + selector);
  }
});

test("no smooth scroll is written without the reduced-motion answer", function () {
  const dirs = [join(here, "features"), join(here, "core"), join(root, "ui", "plugins")];
  const files = [];
  for (const dir of dirs) {
    for (const name of readdirSync(dir)) {
      const path = dir.endsWith("plugins") ? join(dir, name, "app.js") : join(dir, name);
      if (!path.endsWith(".js") || path.endsWith(".test.mjs")) continue;
      try {
        readFileSync(path);
        files.push(path);
      } catch {
        // a plugin directory with no app.js
      }
    }
  }
  assert.ok(files.length > 5, "the scan found nothing to read");
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    const rel = file.replace(root + "/", "");
    for (const m of text.matchAll(/scrollIntoView\(\{[^}]*\}/g)) {
      const call = m[0];
      assert.ok(!/"smooth"/.test(call) || /reduced/i.test(call),
        rel + ": unguarded smooth scroll: " + call);
    }
    for (const m of text.matchAll(/behavior:\s*"smooth"/g)) {
      const line = text.slice(text.lastIndexOf("\n", m.index) + 1, m.index);
      assert.ok(/reduced/i.test(line), rel + ": unguarded smooth behavior");
    }
  }
});
