import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { SLASH_CMDS, slashReady } from "./slash.js";

const here = dirname(fileURLToPath(import.meta.url));

const catalog = JSON.parse(readFileSync(join(here, "..", "..", "..", "commands", "slash.json"), "utf8"));

const appJs = readFileSync(join(here, "..", "app.js"), "utf8");

const slashJs = readFileSync(join(here, "slash.js"), "utf8");

test("slash catalog is data, not a table in app.js", function () {
  assert.ok(Array.isArray(catalog) && catalog.length >= 8);
  const cmds = catalog.map((c) => c.cmd);

  for (const need of ["/compact", "/fork", "/clear", "/model", "/help"]) {
    assert.ok(cmds.includes(need), "missing " + need);
  }

  catalog.forEach(function (c) {
    assert.match(c.cmd, /^\/[a-z-]+$/);
    assert.ok(c.desc && c.desc.length > 0, c.cmd + " needs desc");
    assert.ok(c.click || c.selector || c.view || c.action, c.cmd + " needs an action");
  });
  assert.doesNotMatch(appJs, /var SLASH_CMDS = \[/);
  assert.match(slashJs, /\/webui\/commands\/slash\.json/);
});

test("importing the module fetches nothing; the first caller does", async function () {
  // The catalog used to be fetched from the module body's last line, which is
  // module evaluation: the browser is mid-way through pulling the 32-module
  // eager graph over a six-connection HTTP/1.1 pool at that point, and this
  // one request took a connection away from modules nothing renders without.
  // Nothing paints from the catalog — it is read only while someone types `/`.
  assert.deepEqual(SLASH_CMDS, [], "importing slash.js must not have fetched the catalog");

  let calls = 0;
  const saved = globalThis.fetch;

  globalThis.fetch = function () {
    calls++;

    return Promise.resolve({ ok: true, json: function () { return Promise.resolve(catalog); } });
  };

  try {
    // Two callers, one request: the memo is what makes deferring safe.
    await Promise.all([slashReady(), slashReady()]);
    assert.equal(calls, 1, "the catalog must be fetched once, not once per caller");
    assert.equal(SLASH_CMDS.length, catalog.length);
    assert.ok(SLASH_CMDS.some(function (c) { return c.cmd === "/model"; }));
  } finally {
    globalThis.fetch = saved;
  }
});

test("the two readers await the catalog instead of reading an empty array", function () {
  // Deferring the fetch is only correct if both read sites handle the window
  // where it is still in flight. `renderSlashList` re-draws once it settles;
  // the Enter/Tab completion waits rather than dropping the command. And the
  // re-draw re-arms only while the catalog is still growing: a failed fetch
  // settles the memoized promise with an empty list forever, so an
  // unconditional re-draw would spin the microtask queue without yielding.
  assert.match(
    appJs,
    /if \(!SLASH_CMDS\.length\) slashReady\(\)\.then\(drawSlashListWhenReady, drawSlashListWhenReady\);/,
  );
  assert.match(
    appJs,
    /function drawSlashListWhenReady\(\)\{\s*if \(SLASH_CMDS\.length && slashQuery\(\)\) renderSlashList\(\);/,
  );
  assert.match(appJs, /if \(SLASH_CMDS\.length\) pick\(\);\s*else slashReady\(\)\.then\(pick, pick\);/);
  // The eager call is gone from both the module body and app.js's top level.
  assert.doesNotMatch(slashJs, /^slashReady\(\);$/m);
  assert.doesNotMatch(appJs, /^slashReady\(\);$/m);
});
