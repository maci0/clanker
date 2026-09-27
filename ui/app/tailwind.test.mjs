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
const migrated = [
  "../plugins/activity/app.js",
  "../plugins/search/app.js",
  "../plugins/schedule/app.js",
  "../plugins/mesh/app.js",
  "../plugins/compare/app.js",
  "../plugins/office/app.js",
  "../plugins/music/app.js",
  "../plugins/health/app.js",
  "../plugins/files/app.js",
  "features/todos.js",
  "features/prompts.js",
  "features/knowledge.js",
  "features/goals.js",
  "features/models.js",
  "core/usage.js",
  "features/arena.js",
  "features/fleet.js",
  "features/runs.js",
  "features/board.js",
  "lib/graph.js",
  "core/kit.js",
  "core/ui.js",
  "core/tools.js",
  "core/attachments.js",
  "app.js",
  "index.html",
];

/// Utilities whose arbitrary value has no scale to come from: geometry (a
/// size, an offset, a grid template) and proportions. The line is deliberate —
/// a *colour*, a *padding* or a *radius* written this way is drift and is not
/// on this list, while a 7px bar and a 52ch measure are measurements the
/// cabinet's scales are not asked to carry.
const arbitrary_ok = [
  /^max-w-\[min\(/,
  /^(?:h|w|min-h|min-w|max-h|max-w|basis|top|left|right|bottom|inset|z|grid-cols|grid-rows|ps|pl|pr|pt|pb|stroke|border|scale|rotate|translate-x|translate-y)-\[/,
  // A transition names the properties it covers; there is no token for that list.
  /^transition-\[/,
];
/// A generated-content utility: `content-['…']` is the only spelling for an
/// empty output's placeholder, and the value is a character, not a size.
const content_ok = /^content-\[/;
/// An arbitrary *property* (`[stroke-dasharray:5_9]`) is Tailwind's escape hatch
/// for a property no utility carries at all.
const property_ok = /^\[[a-z-]+:/;
/// A value that reads a `var(--…)` is an expression over the tokens, the same
/// thing a theme key is; a value that says `#1b1b1b` is the drift this test is
/// for, whichever utility it rides on.
const token_value_ok = /var\(--/;
/// An SVG paint server reference, not a colour.
const paint_ok = /^(?:fill|stroke)-\[url\(/;
/// A colour written as a literal, wherever it appears: a hex value, or an
/// `rgb()`/`hsl()` call. `url(#mesh-lamp-idle)` is a fragment reference to a
/// paint server, not a colour, and does not match.
const colour_literal = /#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(/;

/// Split a token on the colons that separate its variants — but not on a colon
/// inside brackets, where `[stroke-dasharray:5_9]` keeps its property and value
/// together and `drop-shadow(1px_2px_5px_…)` keeps its commas.
function splitVariants(token) {
  const parts = [];
  let depth = 0;
  let cur = "";
  for (const ch of token) {
    if (ch === "[") depth += 1;
    else if (ch === "]") depth -= 1;
    if (ch === ":" && depth === 0) { parts.push(cur); cur = ""; continue; }
    cur += ch;
  }
  parts.push(cur);
  return parts;
}
/// Variant prefixes that may carry brackets without being an arbitrary value:
/// a breakpoint, or the element state a ported sheet reached through an
/// attribute selector.
/// An arbitrary *variant* is not an arbitrary value: `[&_input]:h-4` and
/// `has-[:focus-visible]:outline-2` reach a descendant or a child state, and
/// only the utility they carry is checked against the scale.
const variant_bracket_ok = /^(?:\[&|\[[a-z-]+\]|has-\[|max-\[|min-\[|data-\[|group-data-\[|aria-\[|group-aria-\[)/;

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
  // The trailing `[` matters: a data variant emits
  // `.data-\[state\=ok\]\:text-ok[data-state="ok"]`, one compound selector.
  return new RegExp("(^|[\\s,{])" + escapeRe("." + token) + "(?=[\\s,{:\\[])", "m").test(sheet);
}

/// The cabinet half is a plain substring test: `primary` only ever appears in
/// a compound selector (`button.primary`), which the strict form above does not
/// match. It is here to keep a not-yet-ported chrome class legal, not to prove
/// anything about utilities.
function inCabinet(token) {
  return cabinet.includes("." + token);
}

/// The class strings a file actually hands to an element: `api.el(tag, "…")`,
/// a literal class attribute, and the named lists below. Not every string in
/// the file, which would read the view id and the endpoint paths as class
/// names — and a JS file's `class="…"` is usually a *fragment* of markup built
/// by concatenation (`'class="mesh-wire' + …`), so that form is read from HTML
/// only, where it is a whole attribute.
function classStrings(src, isHtml) {
  const out = [];
  for (const m of src.matchAll(/api\.el\(\s*[^,]+,\s*"([^"]*)"/g)) out.push(m[1]);
  if (isHtml) for (const m of src.matchAll(/class="([^"]*)"/g)) out.push(m[1]);
  // The named class lists a ported file keeps at module scope (`ROW_CLASS`,
  // `FACTS_CLASS`) are class strings too: reading only the literals beside
  // `api.el` would leave most of a ported view unchecked.
  for (const m of src.matchAll(/\b[A-Z][A-Z0-9_]*CLASS\s*=\s*"([^"]*)"/g)) out.push(m[1]);
  // `T.ul({ class: "…" })` is the same statement spelled as an object property.
  for (const m of src.matchAll(/class:\s*"([^"]*)"/g)) out.push(m[1]);
  for (const m of src.matchAll(/\.className\s*=\s*"([^"]*)"/g)) out.push(m[1]);
  return out;
}

test("every file that speaks the port's shape is on the ledger", function () {
  // The list above is written by hand, and a file can be ported without being
  // added to it — nothing else in this suite would notice, and the rules it
  // replaced are already deleted from the sheets. Two shapes give it away: a
  // named class list, or a bracketed Tailwind variant (`data-[status=…]`).
  const missing = [];
  for (const rel of migrated.concat([])) void rel; // keep the list referenced
  const { readdirSync } = require("node:fs");
  const isPorted = (src) => /^var [A-Z][A-Z0-9_]*CLASS\s*=/m.test(src) || /:\s*(?:data|group-data|aria|max|min)-?\[/.test(src);
  const files = ["app.js", "preact-boot.js"];
  for (const dir of ["features", "core", "lib"]) {
    for (const entry of readdirSync(join(here, dir))) {
      if (entry.endsWith(".js") && !entry.endsWith(".test.mjs")) files.push(`${dir}/${entry}`);
    }
  }
  for (const rel of files) {
    const src = readFileSync(join(here, rel), "utf8");
    if (isPorted(src) && !migrated.includes(rel)) missing.push(rel);
  }
  for (const dir of readdirSync(join(here, "..", "plugins"))) {
    if (dir.endsWith(".test.mjs")) continue;
    let src = "";
    try { src = readFileSync(join(here, "..", "plugins", dir, "app.js"), "utf8"); } catch { continue; }
    const ported = /^var [A-Z][A-Z0-9_]*CLASS\s*=/m.test(src) || /"[^"]*\b(?:data|group-data|aria)-\[/.test(src);
    if (ported && !migrated.includes(`../plugins/${dir}/app.js`)) missing.push(`../plugins/${dir}/app.js`);
  }
  assert.deepEqual(missing, [], `these files carry the port's shape but are not on the ledger: ${missing.join(", ")}`);
});

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
    for (const classes of classStrings(src, rel.endsWith(".html"))) {
      for (const token of classes.split(/\s+/).filter(Boolean)) {
        // `group` and `peer` are markers a variant names, never rules of their
        // own: Tailwind emits nothing for either.
        if (token === "group" || token === "peer") continue;
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
    for (const classes of classStrings(src, rel.endsWith(".html"))) {
      for (const raw of classes.split(/\s+/).filter(Boolean)) {
        const token = raw.replace(/^[a-z-]+:/, ""); // drop a variant prefix
        const m = rung.exec(token);
        if (!m || m[2]) continue; // px/auto/size utilities are not rungs
        const n = Number(m[1]);
        // 0 is a reset (`margin: 0`), not a rung of the scale.
        if (n !== 0 && (n < 1 || n > 7)) offenders.push(`${rel}: ${raw}`);
      }
    }
  }
  assert.deepEqual(offenders, [], `off-scale spacing: ${offenders.join(", ")}`);
});

test("migrated files use scale utilities, not arbitrary values", function () {
  // `p-[13px]` and `bg-[#fff]` bypass every token in the theme. What is left
  // open: a breakpoint, a grid template, a measurement with no rung (the size
  // of a bar or a measure), a generated character, an arbitrary property, and
  // any value that derives itself from the tokens with `var(--…)`. A literal
  // colour is refused wherever it appears.
  const offenders = [];
  for (const rel of migrated) {
    const src = readFileSync(join(here, rel), "utf8");
    for (const classes of classStrings(src, rel.endsWith(".html"))) {
      for (const token of classes.split(/\s+/).filter(Boolean)) {
        // A variant may name a breakpoint or an element state in brackets;
        // that is not an arbitrary value. The check is on what the utility
        // itself does, so only the last segment counts — and an unknown
        // bracketed variant is one more thing this list has not seen.
        const parts = splitVariants(token);
        for (const part of parts.slice(0, -1)) {
          if (!part.includes("[")) continue;
          if (variant_bracket_ok.test(part)) continue;
          offenders.push(`${rel}: ${token}`);
        }
        // Both lists are checked against the utility, not the whole token:
        // a bracketed variant is the previous loop's business.
        const utility = parts[parts.length - 1];
        if (!utility.includes("[")) continue;
        if (colour_literal.test(utility)) {
          offenders.push(`${rel}: ${token} (colour literal)`);
          continue;
        }
        if (content_ok.test(utility)) continue;
        if (property_ok.test(utility)) continue;
        if (token_value_ok.test(utility)) continue;
        if (paint_ok.test(utility)) continue;
        if (arbitrary_ok.some((re) => re.test(utility))) continue;
        offenders.push(`${rel}: ${token}`);
      }
    }
  }
  assert.deepEqual(offenders, [], `arbitrary values: ${offenders.join(", ")}`);
});
