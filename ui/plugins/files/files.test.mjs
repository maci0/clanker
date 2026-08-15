// Contract on the shipped Files stylesheet: the listing must not sit in a
// leftover 40% track when the preview is closed, and plugin-local buttons
// must beat the host's 40px accent-pill rule.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, "app.css"), "utf8");
const host = readFileSync(join(here, "../../app/app.css"), "utf8");

test("host accent pill is primary and submit only", function () {
  assert.match(host, /button\.primary:where\(:not\(\.pf-v6-c-button\)\)/);
  assert.doesNotMatch(
    host,
    /button:where\(:not\(\.pf-v6-c-button\)\)\s*\{[^}]*background:\s*var\(--accent\)/,
  );
});

test("Files listing fills the column until a preview is open", function () {
  assert.match(css, /\.files-panes\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/);
  assert.doesNotMatch(
    css,
    /\.files-panes\s*\{[^}]*grid-template-columns:\s*40%\s+1fr/,
  );
  assert.match(css, /\.files-panes:has\(\.files-right:not\(\[hidden\]\)\)/);
});

test("Files filter empty state offers to clear the filter", function () {
  const js = readFileSync(join(here, "app.js"), "utf8");
  assert.match(js, /files-clear-filter/);
  assert.match(js, /Clear filter/);
  assert.match(js, /Filter by name/);
  assert.match(css, /\.files-clear-filter\s*\{/);
});

test("Files folder load error offers to try again", function () {
  const js = readFileSync(join(here, "app.js"), "utf8");
  assert.match(js, /Could not open this folder/);
  assert.match(js, /Try again/);
  assert.doesNotMatch(js, /"Error: "\s*\+\s*err\.message/);
});

test("Files file open error shows in the preview with retry", function () {
  const js = readFileSync(join(here, "app.js"), "utf8");
  assert.match(js, /Could not open this file/);
  assert.match(js, /openFile\(path, name\)/);
  assert.match(js, /rightPane\.hidden = false/);
});

test("Files buttons reset the host pill so filenames stay compact", function () {
  assert.match(css, /:where\(#view-files\)\s*button:where\(:not\(\.secondary\)\)/);
  assert.match(css, /\.files-open\s*\{[^}]*min-height:\s*28px/);
});
