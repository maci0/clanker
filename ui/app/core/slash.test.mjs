import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

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
