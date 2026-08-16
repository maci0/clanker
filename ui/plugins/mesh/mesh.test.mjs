import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "app.js"), "utf8");
const css = readFileSync(join(dir, "app.css"), "utf8");
const spec = readFileSync(join(dir, "plugin.json"), "utf8");

test("Mesh is a Watch plugin over the mesh HTTP control plane", function () {
  assert.match(spec, /"name": "mesh"/);
  assert.match(spec, /"group": "Watch"/);
  assert.match(js, /clanker\.registerView/);
  assert.match(js, /\/api\/mesh\/status/);
  assert.match(js, /\/api\/mesh\/join/);
  assert.match(js, /\/api\/mesh\/leave/);
  assert.match(js, /\/api\/mesh\/pending/);
  assert.match(js, /Admit/);
  assert.match(js, /Deny/);
});

test("mesh-off and empty member lists are visible, not only a status line", function () {
  assert.match(js, /Mesh is off\. Set modules\.mesh = true/);
  assert.match(js, /No members\. Join a listen address below/);
  assert.match(js, /No pending joins/);
  assert.match(js, /Try again/);
});

test("self-leave asks before dropping every member", function () {
  assert.match(js, /api\.confirm\("Leave the mesh\?/);
});

test("join field stays 16px on a phone so iOS does not zoom", function () {
  assert.match(css, /@media \(max-width: 40rem\) \{[\s\S]*\.mesh-join-form input \{ font-size: 16px; \}/);
});
