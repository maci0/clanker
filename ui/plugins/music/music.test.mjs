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
