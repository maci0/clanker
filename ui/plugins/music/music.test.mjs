import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "app.js"), "utf8");
const manifest = JSON.parse(readFileSync(join(dir, "plugin.json"), "utf8"));

test("music boot calls ensure only after Music exists", () => {
  function el() {
    const node = {
      style: {},
      dataset: {},
      className: "",
      textContent: "",
      children: [],
      appendChild(child) { this.children.push(child); child.isConnected = true; return child; },
      setAttribute() {},
      addEventListener() {},
      querySelector() { return null; },
      querySelectorAll() { return []; },
    };
    return node;
  }
  const body = el();
  const sandbox = {
    console,
    document: {
      body,
      createElement: el,
      querySelector() { return null; },
      querySelectorAll() { return []; },
      documentElement: el(),
    },
    Audio: function Audio() {
      return { preload: "", paused: true, currentTime: 0, addEventListener() {} };
    },
  };
  sandbox.window = sandbox;
  sandbox.clanker = {
    registerView(spec) {
      spec.boot({
        storage: { get() { return null; }, set() {} },
        icon() { return el(); },
        showView() {},
      });
    },
  };
  vm.createContext(sandbox);
  assert.doesNotThrow(() => vm.runInContext(js, sandbox, { filename: "ui/plugins/music/app.js" }));
  assert.equal(body.children.length, 1);
  assert.equal(body.children[0].id, "music-dock");
});

test("music plugin registers a view and a dock", () => {
  assert.equal(manifest.name, "music");
  assert.match(js, /clanker\.registerView/);
  assert.match(js, /boot(?::\s*function|\s*\()/);
  assert.match(js, /music-dock/);
  assert.doesNotMatch(js, /innerHTML/);
  assert.doesNotMatch(js, /eval\(/);
  assert.match(js, /bg-surface/);
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
  // The note is the error line: a hook attribute for setLastError to find,
  // and a danger reading for the operator.
  assert.match(js, /data-music-note/);
  assert.match(js, /text-danger/);
});

// Every other persistent removal on this page asks first (sessions,
// workspaces, cards, collections, prompts, peers). The playlist's Remove is one
// tap from the row currently playing, persists the loss, and revokes the file
// object URL, so there is nothing to bring it back with.
test("removing a track asks first and says which track went", () => {
  assert.match(js, /api\.confirm\("Remove \\"" \+ t\.title \+ "\\" from the playlist\?"/);
  assert.match(js, /confirmLabel: "Remove"/);
  // And the removal is announced: the row carrying the button is the row that
  // disappears, so without a toast the press looks like nothing happened.
  assert.match(js, /api\.toast\("Removed \\"" \+ gone\.title \+ "\\"\."\)/);
});

test("music URL field is 16px on a phone so iOS does not zoom", () => {
  // The plugin ships no sheet: its field is a plain `type="url"` input, which
  // the page-wide 40rem guard covers (harden.test.mjs pins that guard). What
  // this checks is that the field still qualifies for it.
  assert.match(js, /url\.type = "url"/);
  const host = readFileSync(join(dir, "..", "..", "app", "tailwind.src.css"), "utf8");
  assert.match(host, /@media \(max-width: 40rem\) \{[\s\S]*input\[type="url"\]/);
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
  const table = icons.slice(icons.indexOf("ICON_PATHS = {"), icons.indexOf("\n},\n"));
  const known = new Set();
  for (const m of table.matchAll(/^\s{2}([A-Za-z][A-Za-z0-9]*):\s*\[/gm)) known.add(m[1]);
  assert.ok(known.size > 20, "read the icon grid, not an empty slice");
  assert.match(icons, /if \(!Object\.hasOwn\(ICON_PATHS, name\)\) \{\s*return document\.createElement\("span"\)/,
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
