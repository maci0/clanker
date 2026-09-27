import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

// The Tailwind half of the sheet contract.
//
// ui/app/tailwind.css is a *committed* build product: the guest embeds it at
// comptime and `clanker serve` has no build step, so the file in the tree is
// what the browser gets. That makes two mistakes invisible by eye — a utility
// written into markup and never regenerated (Tailwind emits nothing for it and
// the element silently inherits), and a theme value naming a token app.css
// does not declare (a `var()` with no declaration computes to nothing, so the
// property is simply dropped).
//
// Both are caught here against the shipped bytes. The migrated-file list is
// the ledger of this port: a file moves onto the list when its cabinet rules
// are deleted, and while it is on the list every class in it must resolve.

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "tailwind.src.css"), "utf8");
const built = readFileSync(join(here, "tailwind.css"), "utf8");
const appCss = readFileSync(join(here, "app.css"), "utf8");
const viewsCss = readFileSync(join(here, "views.css"), "utf8");

/// Files whose class strings are Tailwind utilities. Add a path only with the
/// rules it replaces deleted in the same change.
const migrated = ["../plugins/activity/app.js"];

/// Utilities whose arbitrary value is a breakpoint or a real measurement, not
/// a colour or a size that should have been a token.
const arbitrary_ok = [/^max-\[40rem\]:/];

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Generated selectors escape `.`, `:` and `[`; unescaping the sheet once is
// cheaper than escaping every candidate class name to match it. The cabinet
// sheets are unescaped too, because a migrated file still carries the chrome
// classes it has not been moved off yet (`section-head`, `secondary`).
const plain = built.replace(/\\(.)/g, "$1");
const cabinet = (appCss + viewsCss).replace(/\\(.)/g, "$1");

function hasSelector(sheet, token) {
  return new RegExp("(^|[\\s,{])" + escapeRe("." + token) + "(?=[\\s,{:])", "m").test(sheet);
}

/// The cabinet half is a plain substring test: `primary` only ever appears in
/// a compound selector (`button.primary`), which the strict form above does not
/// match. It is here to keep a not-yet-ported chrome class legal, not to prove
/// anything about utilities.
function inCabinet(token) {
  return cabinet.includes("." + token);
}

/// The class strings a file actually hands to an element: `api.el(tag, "…")`
/// and a literal class attribute. Not every string in the file, which would
/// read the view id and the endpoint paths as class names.
function classStrings(src) {
  const out = [];
  for (const m of src.matchAll(/api\.el\(\s*[^,]+,\s*"([^"]*)"/g)) out.push(m[1]);
  for (const m of src.matchAll(/class="([^"]*)"/g)) out.push(m[1]);
  return out;
}

test("the compiled sheet is the build of the source beside it", function () {
  assert.match(built, /^\/\*! tailwindcss v4\./, "tailwind.css must be a Tailwind build");
  assert.match(source, /@import "tailwindcss\/theme\.css"/);
  assert.match(source, /@import "tailwindcss\/utilities\.css"/);
  // Preflight is deliberately deferred until the cabinet sheets are gone; if
  // it lands here first, every unported view repaints at once.
  assert.ok(!/@import "tailwindcss\/preflight/.test(source),
    "preflight lands with the last cabinet sheet, not before");
});

test("every token the theme reads is declared by a shipped sheet", function () {
  // A theme value is `var(--token)`, never a copy, so a misspelled name is a
  // silently dead utility rather than a visible difference.
  const declared = new Set();
  for (const m of (appCss + viewsCss + source).matchAll(/(--[a-z0-9-]+)\s*:/g)) declared.add(m[1]);
  const missing = [];
  const theme = source.slice(source.indexOf("@theme"));
  for (const m of theme.matchAll(/var\((--[a-z0-9-]+)\)/g)) {
    if (!declared.has(m[1])) missing.push(m[1]);
  }
  assert.deepEqual(missing, [], `tailwind.src.css reads tokens nothing declares: ${missing.join(", ")}`);
});

test("every class a migrated file uses resolves in a shipped sheet", function () {
  // The utility has to be in the compiled sheet — a class written into markup
  // and never rebuilt emits no rule at all, and the element silently inherits.
  // A chrome class still defined in app.css is legal until that view moves.
  const missing = [];
  for (const rel of migrated) {
    const src = readFileSync(join(here, rel), "utf8");
    for (const classes of classStrings(src)) {
      for (const token of classes.split(/\s+/).filter(Boolean)) {
        if (hasSelector(plain, token) || inCabinet(token)) continue;
        missing.push(`${rel}: ${token}`);
      }
    }
  }
  assert.deepEqual(missing, [],
    `classes with no rule in any shipped sheet (rebuild with \`bun run css:build\`):\n${missing.join("\n")}`);
});

test("migrated files keep padding, margin and gap on a cabinet rung", function () {
  // Tailwind's spacing is one multiplier for every numeric utility, but only
  // rungs 1-7 are the cabinet scale; the rest is geometry (width, height,
  // basis). Padding and gap off the scale is the drift this port would
  // otherwise reintroduce one `gap-2.5` at a time.
  const rung = /^-?(?:p|m|gap|gap-[xy]|space-[xy]|px|py|pt|pb|pl|pr|mx|my|mt|mb|ml|mr)-(?:(\d+)|(px|auto))$/;
  const offenders = [];
  for (const rel of migrated) {
    const src = readFileSync(join(here, rel), "utf8");
    for (const classes of classStrings(src)) {
      for (const raw of classes.split(/\s+/).filter(Boolean)) {
        const token = raw.replace(/^[a-z-]+:/, ""); // drop a variant prefix
        const m = rung.exec(token);
        if (!m || m[2]) continue; // px/auto/size utilities are not rungs
        const n = Number(m[1]);
        if (n < 1 || n > 7) offenders.push(`${rel}: ${raw}`);
      }
    }
  }
  assert.deepEqual(offenders, [], `off-scale spacing: ${offenders.join(", ")}`);
});

test("migrated files use scale utilities, not arbitrary values", function () {
  // `p-[13px]` and `bg-[#fff]` bypass every token in the theme. Breakpoints and
  // the two documented measurements are the exception.
  const offenders = [];
  for (const rel of migrated) {
    const src = readFileSync(join(here, rel), "utf8");
    for (const classes of classStrings(src)) {
      for (const token of classes.split(/\s+/).filter(Boolean)) {
        if (!token.includes("[")) continue;
        if (arbitrary_ok.some((re) => re.test(token))) continue;
        offenders.push(`${rel}: ${token}`);
      }
    }
  }
  assert.deepEqual(offenders, [], `arbitrary values: ${offenders.join(", ")}`);
});
