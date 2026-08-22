// Named palettes are data under themes/*.json. The page applies those
// tokens; app.css only keeps :root and the system dark media query.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const themesDir = join(here, "..", "..", "..", "themes");
const themeJs = readFileSync(join(here, "theme.js"), "utf8");

const REQUIRED = ["--code-bg", "--code-fg", "--bg", "--fg", "--accent", "--paper"];

test("every themes/*.json file is a named palette with tokens", function () {
  const files = readdirSync(themesDir).filter((n) => n.endsWith(".json")).sort();
  assert.ok(files.length >= 10, "expected the shipped palettes, got " + files.join(","));
  for (const file of files) {
    const rec = JSON.parse(readFileSync(join(themesDir, file), "utf8"));
    const id = file.slice(0, -".json".length);
    assert.equal(rec.name, id, file + " name must match the filename");
    assert.match(rec.scheme, /^(light|dark)$/, file + " scheme");
    assert.equal(typeof rec.order, "number", file + " order");
    assert.ok(rec.tokens && typeof rec.tokens === "object", file + " tokens");
    for (const key of REQUIRED) {
      assert.ok(rec.tokens[key], file + " missing " + key);
    }
  }
});

test("theme.js loads the catalog from disk, not a hardcoded list", function () {
  assert.match(themeJs, /\/webui\/themes\//);
  assert.match(themeJs, /catalog\.json/);
  assert.match(themeJs, /export function themesReady/);
  assert.doesNotMatch(themeJs, /export var THEMES = \["system", "light"/);
});

// The picker's keyboard and swatch behaviour. These landed as three improve
// passes (imp-1787095166595783866, imp-1787096287238773039,
// imp-1787097418987953973), were removed wholesale in 48d03d8b, and are
// restored here; the pins exist so a third round-trip is a red test.
const appCss = readFileSync(join(here, "..", "app.css"), "utf8");

test("the picker walks its options with ArrowUp/ArrowDown and wraps", function () {
  assert.match(themeJs, /ArrowDown/);
  assert.match(themeJs, /ArrowUp/);
  // Wrap at both ends, the same modulo walk core/modelpicker.js uses. The
  // first version clamped going down and wrapped going up.
  assert.match(themeJs, /\(at \+ delta \+ opts\.length\) % opts\.length/);
  assert.match(themeJs, /scrollIntoView\(\{ block: "nearest" \}\)/);
});

test("the picker leaves Enter/Space to the option buttons", function () {
  // Rows are real <button>s, so the browser already fires click on Enter and
  // Space. A keydown arm for them is a hand-rolled duplicate that also
  // preventDefault()s the native path.
  assert.doesNotMatch(themeJs, /e\.key === "Enter"/);
  assert.doesNotMatch(themeJs, /e\.key === " "/);
});

test("closing the picker hands focus back to the toggle", function () {
  // A hidden element keeps focus: without this the page falls back to <body>
  // and the next Tab restarts at the top of the document.
  assert.match(themeJs, /function closePicker\([^)]*\)[\s\S]*?_picker\.contains\(document\.activeElement\)/);
  assert.match(themeJs, /function closePicker\([^)]*\)[\s\S]*?anchor\.focus\(\)/);
});

test("Tab closes the picker without trapping focus", function () {
  assert.match(themeJs, /e\.key === "Tab"[\s\S]*?closePicker\(false\)/);
  assert.doesNotMatch(themeJs, /e\.key === "Tab"[\s\S]{0,80}?preventDefault/);
});

test("each option carries a swatch laid out beside its label", function () {
  assert.match(themeJs, /theme-picker__swatch/);
  assert.match(themeJs, /tokens\["--bg"\]/);
  // .model-picker__option is flex-direction: column, so an unqualified swatch
  // span renders stacked above the label with its margin doing nothing. The
  // theme rows need their own row-direction modifier.
  assert.match(themeJs, /theme-picker__option/);
  assert.match(appCss, /\.theme-picker__option \{[^}]*flex-direction: row/);
  assert.match(appCss, /\.theme-picker__swatch \{/);
  assert.ok(
    appCss.indexOf(".theme-picker__option {") > appCss.indexOf(".model-picker__option {"),
    "the theme modifier must come after .model-picker__option to win the cascade"
  );
});
