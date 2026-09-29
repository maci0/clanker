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
  "preact", "html", "signals", "kit",
  "ui", "overlay", "stream", "text", "dom", "color", "goals",
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
  assert.notEqual(src.indexOf("export function pluginApi"), -1, "pluginApi moved out of core/plugins.js");
  // The returned object literal's own members sit at exactly four spaces;
  // anything deeper belongs to a member's body, not the surface.
  const keys = [...pluginApiBody(src).matchAll(/^ {4}([a-zA-Z_]\w*):/gm)].map((m) => m[1]);
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

/* A built-in view is not a plugin yet, but the day it becomes one it can only
   reach what pluginApi() hands over. A core helper a feature view imports today
   and pluginApi() does not carry is therefore a gap that blocks the migration,
   and nothing else in the tree notices it: the plugin suites only look at
   ui/plugins/, so the missing member is invisible until the view moves.

   EXPOSED is that diff, kept as data. Each name is the api path a plugin uses
   to reach the same core export, and the test checks both directions: every
   core import a feature view makes is listed here, and every listed path is a
   real member of pluginApi(). Adding a core helper to a feature view without
   adding it here fails; renaming an api group fails the other half. */
const EXPOSED = {
  // core/ui.js
  T: "van.tags", add: "van.add", bind: "van.bind", state: "van.state",
  UI: "ui.kit", showLoadError: "ui.loadError", skeletonRows: "ui.skeletonRows",
  toolRow: "ui.toolRow", runDetail: "ui.runDetail", requireText: "ui.requireText",
  showLoading: "ui.loading",
  wireRefresh: "ui.refresh", uiConfirm: "confirm", uiPrompt: "prompt", toast: "toast",
  // core/utils.js
  readJson: "getJSON", postJson: "postJSON",
  fmtBytes: "fmt.bytes", fmtInt: "fmt.int", fmtCost: "fmt.cost",
  formatChatTime: "fmt.time", fmtMs: "fmt.ms", fmtPct: "fmt.pct", fmtUsd: "fmt.usd",
  fmtDeadline: "fmt.deadline", fmtUnit: "fmt.unit", plural: "fmt.plural",
  searchFold: "fmt.fold", runLabel: "fmt.runLabel",
  providerUnusableReason: "fmt.providerReason",
  clip: "text.clip", escapeHtml: "text.escape", searchFoldFind: "foldFind",
  peerColor: "color.peer", themeToken: "color.token",
  cssColorAlpha: "color.alpha", cssColorMix: "color.mix",
  // core/overlay.js, core/stream.js, core/icons.js
  openOverlay: "overlay.open", closeOverlay: "overlay.close",
  trapOverlayTab: "overlay.trapTab",
  onLive: "onLive", liveOk: "stream.ok", makeLineSplitter: "stream.lines",
  pumpInto: "stream.pump", icon: "icon",
  // core/vendor.js
  copyText: "dom.copy", scrollTo: "dom.scrollTo", paintTomlInto: "dom.toml",
  loadD3: "dom.d3", reducedMotion: "dom.reducedMotion",
  // core/goals.js, core/labels.js
  goalSortKey: "goals.sortKey", goalFields: "goals.fields",
  goalStatusLabel: "goals.statusLabel", goalWorktreeTitle: "goals.worktreeTitle",
  goalPinnedColumn: "goals.pinnedColumn",
};

/* The object literal pluginApi() returns. It closes at two spaces, which is
   the only such line in the function: every group inside it closes deeper. */
function pluginApiBody(src) {
  const start = src.indexOf("export function pluginApi");
  const end = src.indexOf("\n  }", start);
  return src.slice(start, end === -1 ? src.length : end);
}

function apiSurface() {
  const src = fs.readFileSync(path.join(here, "..", "app", "core", "plugins.js"), "utf8");
  const body = pluginApiBody(src);
  const top = new Set([...body.matchAll(/^ {4}([a-zA-Z_]\w*):/gm)].map((m) => m[1]));
  const nested = new Set();
  // A group is written on one line (`van: { tags: T, state: state }`) or across
  // several, and both spellings are read by the same match: the group body
  // runs to its own closing brace. A group that grows a nested object stops
  // the scan at that inner brace, and the EXPOSED check below then names the
  // member it cannot see.
  const membersOf = (text) => text.split(",")
    .map((part) => part.trim().match(/^([a-zA-Z_]\w*):/))
    .filter(Boolean).map((m) => m[1]);
  for (const m of body.matchAll(/^ {4}([a-zA-Z_]\w*):\s*\{([^}]*)\}/gm)) {
    for (const k of membersOf(m[2])) nested.add(`${m[1]}.${k}`);
  }
  // `fmt` is built by a factory rather than written inline, so its keys live
  // in that function's return object.
  const fmtStart = src.indexOf("function fmt()");
  if (fmtStart !== -1) {
    const fmtEnd = src.indexOf("\n  }", fmtStart);
    const open = src.indexOf("return {", fmtStart);
    for (const k of membersOf(src.slice(open + "return {".length, fmtEnd))) nested.add(`fmt.${k}`);
  }
  return { top, nested };
}

/* The core modules a feature view is allowed to be written against. Imports of
   another feature (./board.js, ./goals.js) and of ../lib/* are out of scope:
   a plugin cannot import a first-party view either, and that pairing is its
   own question. */
const CORE = "../core/";

function coreImports(src) {
  const names = new Set();
  for (const m of stripComments(src).matchAll(/import \{([^}]*)\} from "([^"]*)"/g)) {
    if (!m[2].includes(CORE)) continue;
    for (const part of m[1].split(",")) {
      const name = part.trim().split(/\s+as\s+/)[0].trim();
      if (name) names.add(name);
    }
  }
  return names;
}

test("every core helper a built-in view imports is reachable from pluginApi", () => {
  const features = path.join(here, "..", "app", "features");
  const problems = [];
  for (const file of fs.readdirSync(features).sort()) {
    if (!file.endsWith(".js")) continue;
    for (const name of coreImports(fs.readFileSync(path.join(features, file), "utf8"))) {
      if (!(name in EXPOSED)) {
        problems.push(`${file}: imports ${name}, which pluginApi() does not carry; add it to pluginApi() and to EXPOSED here`);
      }
    }
  }
  assert.equal(problems.length, 0, problems.join("\n"));
});

test("every EXPOSED path is a real pluginApi member, and a known capability", () => {
  const { top, nested } = apiSurface();
  const problems = [];
  for (const [name, apiPath] of Object.entries(EXPOSED)) {
    if (apiPath === null) continue;
    const [head, ...rest] = apiPath.split(".");
    const cap = ALIAS[head] || head;
    if (!KNOWN.includes(cap)) {
      problems.push(`${name}: api.${head} has no capability name; add "${cap}" here and to webui_addon_logic.zig`);
    }
    if (rest.length === 0) {
      if (!top.has(head)) problems.push(`${name}: pluginApi() has no "${head}" member (api.${apiPath})`);
    } else if (!nested.has(apiPath)) {
      problems.push(`${name}: pluginApi() has no "${apiPath}" member`);
    }
  }
  assert.equal(problems.length, 0, problems.join("\n"));
});
