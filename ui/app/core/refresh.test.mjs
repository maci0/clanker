// Every "Refresh" button the page ships must have something behind it, and
// must say something while it works.
//
// Three of them (Goal activity, Tools, Usage) shipped with an id, a slot in
// app.js's element map, and no listener anywhere: pressing them did nothing
// and looked no different from pressing one that worked. The rest were wired
// a dozen different ways, half of them without disabling, so a slow load left
// the operator to guess whether the press registered.
//
// This walks the shipped HTML for every Refresh control and then walks the
// shipped JS for how it is wired, so a new view cannot add a fourth dead
// button or a fifteenth hand-rolled handler.
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = join(here, "..");
const html = readFileSync(join(appRoot, "index.html"), "utf8");

function jsFiles(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...jsFiles(full));
    else if (name.endsWith(".js")) out.push(full);
  }
  return out;
}

const files = jsFiles(appRoot).map((f) => ({ path: f, text: readFileSync(f, "utf8") }));
const sources = files.map((f) => f.text).join("\n");

// Buttons whose label starts with "Refresh". `Refresh catalog` posts rather
// than reloading a list, but the same press/wait/feedback contract applies.
function refreshButtonIds() {
  const ids = [];
  const re = /<button[^>]*id="([a-z0-9-]+)"[^>]*>([^<]*)<\/button>/g;
  let m;
  while ((m = re.exec(html))) {
    if (/^Refresh\b/.test(m[2].trim())) ids.push(m[1]);
  }
  return ids;
}

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Where the button is picked out of the DOM, and under what name. Covers the
// two spellings the app uses: a local `var x = byId("id")` inside a view's
// bind, and a key in app.js's `el` map.
function bindings(id) {
  const found = [];
  const local = new RegExp(
    "(?:var|let|const)\\s+([A-Za-z_$][\\w$]*)\\s*=\\s*(?:byId|f|document\\.getElementById)\\(\"" + esc(id) + "\"\\)"
  );
  const mapped = new RegExp("([A-Za-z_$][\\w$]*)\\s*:\\s*document\\.getElementById\\(\"" + esc(id) + "\"\\)");
  for (const f of files) {
    const a = f.text.match(local);
    if (a) found.push({ path: f.path, name: a[1], scope: f.text });
    const b = f.text.match(mapped);
    if (b) found.push({ path: f.path, name: b[1], scope: sources, mapped: true });
  }
  return found;
}

// The one deliberate exception: the System view's Status refresh restores
// `disabled` to whether a run is in flight, not to false, so it cannot use
// the shared helper without losing that.
const HAND_ROLLED = new Set(["refresh"]);

// The two static scans walk every JS file under ui/app per button id; on a
// loaded machine (or after heavier suites in the same sweep) that can exceed
// bun's 5s default, which reads as a failure rather than slowness. The budget
// below is headroom, not a target: the scans take ~1s warm.
const SCAN_TIMEOUT = 30_000;

test("every Refresh button in the page is picked up by a script", { timeout: SCAN_TIMEOUT }, function () {
  const ids = refreshButtonIds();
  assert.ok(ids.length >= 15, "expected the page's Refresh buttons, found " + ids.length);
  for (const id of ids) {
    assert.ok(bindings(id).length, "Refresh button #" + id + " is never read by any script");
  }
});

test("every Refresh button has a handler that gives busy feedback", { timeout: SCAN_TIMEOUT }, function () {
  for (const id of refreshButtonIds()) {
    if (HAND_ROLLED.has(id)) continue;
    const where = bindings(id);
    assert.ok(where.length, "Refresh button #" + id + " is never read by any script");
    const ok = where.some((b) => {
      const n = esc(b.name);
      const prefix = b.mapped ? "(?:el|_el)\\." : "";
      return new RegExp("wireRefresh\\(\\s*" + prefix + n + "\\b").test(b.scope) ||
        new RegExp(prefix + n + "\\.disabled\\s*=").test(b.scope);
    });
    assert.ok(ok, "Refresh button #" + id + " has no wireRefresh and no disable: press it and nothing says it worked");
  }
});

test("wireRefresh re-enables the button whether the load resolves or rejects", { timeout: SCAN_TIMEOUT }, async function () {
  const { wireRefresh } = await import("./utils.js");
  const calls = [];
  function fakeButton() {
    let handler = null;
    return {
      disabled: false,
      addEventListener(_, fn) { handler = fn; },
      press() { handler(); },
    };
  }

  const ok = fakeButton();
  let settle;
  wireRefresh(ok, () => new Promise((res) => { settle = res; }));
  ok.press();
  assert.equal(ok.disabled, true, "button stays disabled while the load runs");
  settle();
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(ok.disabled, false, "button comes back when the load resolves");

  const bad = fakeButton();
  wireRefresh(bad, () => Promise.reject(new Error("offline")));
  bad.press();
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(bad.disabled, false, "a failed load must not leave the button dead");

  const sync = fakeButton();
  wireRefresh(sync, () => { calls.push(1); });
  sync.press();
  assert.equal(sync.disabled, false, "a synchronous load re-enables immediately");
  assert.equal(calls.length, 1);

  const twice = fakeButton();
  wireRefresh(twice, () => {});
  wireRefresh(twice, () => {});
  assert.equal(twice._refreshBound, true, "binding is idempotent per button");
});
