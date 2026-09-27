// The command palette has to work on the first Ctrl+K of a page load, before
// any lazy view module has been imported. It indexes `refs` that the Runs
// module fills in on demand, so the shipped stand-ins are part of its
// contract: `allRunsHolder` was null, paletteEntries() threw on it, and the
// overlay opened empty and dead on every visit that had not opened Runs
// first — and stayed that way on each keystroke, since every key re-renders.
//
// This drives the shipped module against the refs literal as app.js actually
// ships it, so a `null` put back into that literal fails here.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const appSource = readFileSync(join(here, "..", "app.js"), "utf8");

function shippedPaletteRefs() {
  const start = appSource.indexOf("var paletteRefs = {");
  assert.ok(start !== -1, "app.js still declares paletteRefs");
  const open = appSource.indexOf("{", start);
  let depth = 0;
  let end = -1;
  for (let i = open; i < appSource.length; i++) {
    const ch = appSource[i];
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) { end = i; break; }
    }
  }
  assert.ok(end !== -1, "the paletteRefs literal is closed");
  return new Function("return " + appSource.slice(open, end + 1) + ";")();
}

function stubNode() {
  return { addEventListener: function () {}, value: "", textContent: "" };
}

test("the palette indexes its refs before any lazy view module has loaded", async function () {
  const refs = shippedPaletteRefs();
  // Runs is the one ref no startup path fills in, so it must ship usable.
  assert.deepEqual(
    refs.allRunsHolder, { list: [] },
    "paletteRefs.allRunsHolder is the lazy Runs list and must not be null"
  );

  // What app.js's own startup lines assign before any lazy import.
  const startup = {
    knownSessionsHolder: { list: [] },
    allToolsHolder: { list: [] },
    sessionLabel: function (s) { return s.title || s.id; },
    runLabel: function (r) { return r.run_id; }
  };
  Object.assign(refs, startup);
  for (const key of Object.keys(refs)) {
    assert.notEqual(refs[key], null, "paletteRefs." + key + " is null; the palette dereferences it");
  }

  const { bindPalette, paletteEntries } = await import("./palette.js");
  bindPalette({
    VIEWS: ["chat", "runs", "kanban"],
    showView: function () {},
    el: {
      paletteOpen: stubNode(), paletteInput: stubNode(), paletteList: stubNode(),
      palette: stubNode(), help: stubNode()
    },
    refs: refs,
    setRailOpen: function () {},
    switchSession: function () {},
    openRun: function () {},
    renderBoard: function () {},
    showToolDetail: function () {},
    setOpenCardId: function () {}
  });

  const entries = paletteEntries();
  assert.ok(Array.isArray(entries), "paletteEntries returned a list");
  // The always-present rows: the theme and shortcut actions come from the
  // element map, so an empty-but-live palette still lists them.
  assert.ok(entries.length > 0, "an unloaded palette still offers its static actions");
});
