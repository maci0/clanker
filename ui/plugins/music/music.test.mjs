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
