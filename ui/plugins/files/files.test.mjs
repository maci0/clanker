// Contract on the shipped Files view: the listing must not sit in a leftover
// 40% track when the preview is closed, the plugin's own controls must not
// inherit the host's button shape, and the phone layout keeps the names.
//
// The plugin ships no stylesheet (the Tailwind port deleted it), so what used
// to be asserted against `app.css` is asserted against the class strings the
// view builds its elements from, plus the page sheet where the styling is the
// page's own. ui/app/tailwind.test.mjs proves every one of these utilities has
// a rule in the compiled sheet; these are the layout and hit-target contracts.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(here, "app.js"), "utf8");
const host = readFileSync(join(here, "../../app/app.css"), "utf8");

/// The utility string a named class constant holds, including what it is built
/// from (`"…" + PLAIN_BTN`).
function classOf(name) {
  const decl = new RegExp("\\b" + name + " = [\\s\\S]*?;").exec(js);
  assert.ok(decl, `${name} is still a class list`);
  const parts = [];
  for (const q of decl[0].matchAll(/"([^"]*)"|\+\s*\b([A-Z_]+)\b/g)) {
    if (q[1] !== undefined) { parts.push(q[1]); continue; }
    const base = new RegExp("\\b" + q[2] + " = \"([^\"]*)\"").exec(js);
    if (base) parts.push(base[1]);
  }
  assert.ok(parts.length, `${name} holds a class string`);
  return parts.join(" ");
}

test("host accent pill is primary and submit only", function () {
  assert.match(host, /button\.primary:where\(:not\(\.pf-v6-c-button\)\)/);
  assert.doesNotMatch(
    host,
    /button:where\(:not\(\.pf-v6-c-button\)\)\s*\{[^}]*background:\s*var\(--accent\)/,
  );
});

test("Files listing fills the column until a preview is open", function () {
  // The closed grid is one track: the listing used to sit in a leftover 40%
  // column reserved for a preview that was `display: none`.
  const panes = classOf("PANES_CLASS");
  assert.match(panes, /grid-cols-\[minmax\(0,1fr\)\]/);
  assert.match(panes, /data-\[preview=open\]:grid-cols-\[minmax\(16rem,1fr\)_minmax\(18rem,1\.15fr\)\]/);
  assert.doesNotMatch(panes, /40% 1fr/);
  // A `:has()` on the child's [hidden] is not a utility, so the parent asks
  // about a flag the JS sets beside it.
  assert.match(js, /panes\.dataset\.preview = "open"/);
  assert.match(js, /panes\.dataset\.preview = ""/);
});

test("Files hidden-only folder offers to show hidden items", function () {
  assert.match(js, /This folder has /);
  assert.match(js, /hidden item/);
  assert.match(js, /Show hidden/);
  assert.match(js, /hiddenBtn\.click\(\)/);
});

test("Files filter is 16px on a phone so iOS does not zoom", function () {
  // The field is a plain `type="search"` input, which the page-wide 40rem
  // guard covers (harden.test.mjs pins the guard). The plugin's own rule for
  // it was dead: the page's `input[type="search"]` selector outranked it.
  assert.match(js, /filterInput\.type = "search"/);
  assert.match(host, /@media \(max-width: 40rem\) \{[\s\S]*input\[type="search"\]:not\(\.pf-v6-c-form-control\)/);
});

test("Files empty nested folder offers to go up", function () {
  assert.match(js, /This folder is empty\./);
  assert.match(js, /Go up/);
  assert.match(js, /cur\.atRoot/);
  assert.match(js, /upBtn\.click\(\)/);
});

test("Files filter empty state offers to clear the filter", function () {
  assert.match(js, /CLEAR_CLASS/);
  assert.match(js, /Clear filter/);
  assert.match(js, /Filter by name/);
  const clear = classOf("CLEAR_CLASS");
  assert.match(clear, /underline/);
  assert.match(clear, /text-accent-text/);
});

test("Files folder load error offers to try again", function () {
  assert.match(js, /Could not open this folder/);
  assert.match(js, /Try again/);
  assert.doesNotMatch(js, /"Error: "\s*\+\s*err\.message/);
});

test("Files file open error shows in the preview with retry", function () {
  assert.match(js, /Could not open this file/);
  assert.match(js, /openFile\(path, name\)/);
  assert.match(js, /rightPane\.hidden = false/);
});

test("Files buttons reset the host pill so filenames stay compact", function () {
  // Every control states its own shape from PLAIN_BTN: a utility class beats
  // the host's element-level button rule, which is what the old
  // `:where(#view-files) button` reset did with a selector.
  assert.match(classOf("PLAIN_BTN"), /bg-transparent/);
  assert.match(classOf("PLAIN_BTN"), /p-0/);
  assert.match(classOf("PLAIN_BTN"), /shadow-none/);
  assert.match(classOf("OPEN_CLASS"), /min-h-7/);
  assert.match(classOf("SORT_CLASS"), /min-h-7/);
  assert.match(classOf("CRUMB_CLASS"), /min-h-7/);
});

test("Files crumbs and rows are 44px on a phone", function () {
  for (const name of ["CRUMB_CLASS", "SORT_CLASS", "OPEN_CLASS", "ROW_CLASS"]) {
    assert.match(classOf(name), /max-\[40rem\]:min-h-11/, `${name} grows to a tap target on a phone`);
  }
});

test("Files listing drops Size and Modified on a phone so names stay on-screen", function () {
  // Size and Modified need 16.5rem of their own; a 20rem phone then scrolls
  // sideways to read a name. Name stays, those two go.
  assert.match(classOf("CELL_CLASS"), /max-\[40rem\]:hidden/);
  assert.match(classOf("ROW_CLASS"), /max-\[40rem\]:grid-cols-\[1\.5rem_minmax\(0,1fr\)\]/);
  assert.match(classOf("HEADER_ROW_CLASS"), /max-\[40rem\]:grid-cols-\[1\.5rem_minmax\(0,1fr\)\]/);
});

test("the selected row is drawn from aria-selected", function () {
  // The highlight and the screen reader's selection are one state, not two:
  // the class that used to carry it (with !important) is now the attribute the
  // listbox already maintains.
  assert.match(classOf("ROW_CLASS"), /aria-selected:border-accent/);
  assert.match(classOf("ROW_CLASS"), /aria-selected:bg-accent-dim/);
  assert.match(js, /setAttribute\("aria-selected","true"\)/);
  assert.doesNotMatch(js, /files-row-active/);
});
