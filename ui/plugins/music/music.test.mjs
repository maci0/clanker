import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "app.js"), "utf8");
const css = readFileSync(join(dir, "app.css"), "utf8");
const manifest = JSON.parse(readFileSync(join(dir, "plugin.json"), "utf8"));

test("music plugin registers a view and a dock", () => {
  assert.equal(manifest.name, "music");
  assert.match(js, /clanker\.registerView/);
  assert.match(js, /boot:\s*function/);
  assert.match(js, /music-dock/);
  assert.doesNotMatch(js, /innerHTML/);
  assert.doesNotMatch(js, /eval\(/);
  assert.match(css, /--surface/);
});

test("playback ticks update chrome in place instead of rebuilding the tree", () => {
  assert.match(js, /function syncChrome/);
  assert.match(js, /addEventListener\("timeupdate", syncChrome\)/);
  assert.doesNotMatch(js, /addEventListener\("timeupdate", draw\)/);
  assert.match(js, /var scrubbing = false/);
});

test("empty playlist and bad URL say what to do next", () => {
  assert.match(js, /No tracks yet\. Add audio files or a URL above to start\./);
  assert.match(js, /Need a full http\(s\) URL/);
  assert.match(js, /Those files are not audio/);
  assert.match(css, /\.music-note/);
});

test("music URL field is 16px on a phone so iOS does not zoom", () => {
  assert.match(css, /@media \(max-width: 40rem\) \{[\s\S]*?\.music-url input \{ font-size: 16px; \}/);
});

// Every glyph the dock draws is a key in the host's icon grid, not a character.
//
// `api.icon` is always supplied by the loader (ui/app/core/plugins.js), and
// `icon()` returns an *empty* <span> for a name it does not know — so a glyph
// that is not in the grid is a blank button, and the `else b.textContent = name`
// fallback in `setGlyph` only runs against a host that predates `api.icon`,
// which is also what a test harness that omits it would exercise. The playlist
// row's Remove button asked for "×" and drew nothing. This walks both files so
// the pair cannot drift again.
test("every glyph name music asks for exists in the host's icon grid", () => {
  const icons = readFileSync(join(dir, "..", "..", "app", "core", "icons.js"), "utf8");
  const table = icons.slice(icons.indexOf("ICON_PATHS = {"), icons.indexOf("export function icon("));
  const known = new Set();
  for (const m of table.matchAll(/^\s{2}([A-Za-z][A-Za-z0-9]*):\s*\[/gm)) known.add(m[1]);
  assert.ok(known.size > 20, "read the icon grid, not an empty slice");
  assert.match(icons, /if \(!paths\) return document\.createElement\("span"\)/,
    "an unknown name still renders as an empty span, so the check below still matters");

  const asked = new Set();
  for (const m of js.matchAll(/\bbtn\(\s*"([^"]+)"/g)) asked.add(m[1]);
  for (const m of js.matchAll(/\bsetGlyph\([^,]+,\s*"([^"]+)"/g)) asked.add(m[1]);
  for (const m of js.matchAll(/\bsetGlyph\([^,]+,\s*[^?]+\?\s*"([^"]+)"\s*:\s*"([^"]+)"/g)) { asked.add(m[1]); asked.add(m[2]); }
  for (const m of js.matchAll(/\bbtn\([^,]*\?\s*"([^"]+)"\s*:\s*"([^"]+)"/g)) { asked.add(m[1]); asked.add(m[2]); }
  assert.ok(asked.size >= 8, "found the glyph call sites");

  const missing = [...asked].filter((n) => !known.has(n));
  assert.deepEqual(missing, [], "these glyph names draw an empty button");
});
