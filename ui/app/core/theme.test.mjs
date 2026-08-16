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
