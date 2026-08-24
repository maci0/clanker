// plugin.json capabilities must name what app.js actually uses. The field is
// a declaration ("names the api members the view actually uses", see
// README.md), not a grant, so an undeclared member makes the manifest lie
// about its own surface and an unknown name is refused on write by the
// webui_addon tool. This suite pins both directions for every shipped,
// non-module addon: used ⊆ declared, and declared ⊆ known.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import url from "node:url";

const here = path.dirname(url.fileURLToPath(import.meta.url));

// Mirrors `capabilities` in tools/zig/webui_addon_logic.zig. Change them
// together: the Zig table refuses unknown names when a plugin.json is written.
const KNOWN = [
  "get", "post", "del", "live", "emit", "confirm", "prompt", "toast",
  "workspace", "icon", "storage", "render", "session", "foldFind",
  "boardTimeline", "el", "status", "fmt", "showView", "van",
  "preact", "html", "signals",
];

// api member -> capability name. Members missing here declare under their
// own name, matching pluginApi() in ui/app/core/plugins.js.
const ALIAS = {
  getJSON: "get",
  postJSON: "post",
  onLive: "live",
  openSession: "session",
};

function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/(^|[^:])\/\/[^\n]*/g, "$1 ");
}

function usedMembers(appJs) {
  const hits = new Set();
  for (const m of stripComments(appJs).matchAll(/\bapi\.([a-zA-Z_]\w*)/g)) {
    const member = m[1];
    if (member === "storage") { hits.add("storage"); continue; }
    hits.add(ALIAS[member] || member);
  }
  return hits;
}

function pluginDirs() {
  return fs.readdirSync(here, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .sort();
}

test("every non-module plugin declares the api members it uses", () => {
  const problems = [];
  for (const name of pluginDirs()) {
    const dir = path.join(here, name);
    const metaPath = path.join(dir, "plugin.json");
    const appPath = path.join(dir, "app.js");
    if (!fs.existsSync(metaPath) || !fs.existsSync(appPath)) continue;
    const meta = JSON.parse(fs.readFileSync(metaPath, "utf8"));
    if (meta.module) continue;
    const declared = new Set(meta.capabilities || []);
    for (const cap of declared) {
      if (!KNOWN.includes(cap)) problems.push(`${name}: unknown capability "${cap}"`);
    }
    for (const used of usedMembers(fs.readFileSync(appPath, "utf8"))) {
      if (!KNOWN.includes(used)) {
        problems.push(`${name}: uses api.${used}, which has no capability name`);
      } else if (!declared.has(used)) {
        problems.push(`${name}: uses api.${used} but does not declare "${used}"`);
      }
    }
  }
  assert.equal(problems.length, 0, problems.join("\n"));
});

test("the known-name list covers every pluginApi method the page offers", () => {
  const src = fs.readFileSync(path.join(here, "..", "app", "core", "plugins.js"), "utf8");
  const start = src.indexOf("export function pluginApi");
  assert.notEqual(start, -1, "pluginApi moved out of core/plugins.js");
  // The returned object literal's own members sit at exactly four spaces;
  // anything deeper belongs to a member's body, not the surface.
  const end = src.indexOf("\n}", start);
  const keys = [...src.slice(start, end).matchAll(/^ {4}([a-zA-Z_]\w*):/gm)].map((m) => m[1]);
  assert.ok(keys.length >= 20, `pluginApi surface parse found only ${keys.length}: ${keys}`);
  for (const key of keys) {
    if (key === "spec") continue;
    const cap = ALIAS[key] || key;
    assert.ok(
      KNOWN.includes(cap),
      `pluginApi().${key} has no capability name; add "${cap}" here and to webui_addon_logic.zig`,
    );
  }
});
