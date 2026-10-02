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

    if (ch === "{") { depth++; }
    else if (ch === "}") {
      depth--;

      if (depth === 0) { end = i; break; }
    }
  }

  assert.ok(end !== -1, "the paletteRefs literal is closed");

  return new Function("return " + appSource.slice(open, end + 1) + ";")();
}

function stubNode() {
  return { addEventListener () {}, value: "", textContent: "" };
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
    sessionLabel (s) { return s.title || s.id; },
    runLabel (r) { return r.run_id; }
  };

  Object.assign(refs, startup);

  for (const key of Object.keys(refs)) {
    assert.notEqual(refs[key], null, "paletteRefs." + key + " is null; the palette dereferences it");
  }

  const { bindPalette, paletteEntries } = await import("./palette.js");
  bindPalette({
    VIEWS: ["chat", "runs", "kanban"],
    showView () {},
    el: {
      paletteOpen: stubNode(), paletteInput: stubNode(), paletteList: stubNode(),
      palette: stubNode(), help: stubNode()
    },
    refs,
    setRailOpen () {},
    switchSession () {},
    openRun () {},
    renderBoard () {},
    showToolDetail () {},
    setOpenCardId () {}
  });

  const entries = paletteEntries();
  assert.ok(Array.isArray(entries), "paletteEntries returned a list");
  // The always-present rows: the theme and shortcut actions come from the
  // element map, so an empty-but-live palette still lists them.
  assert.ok(entries.length > 0, "an unloaded palette still offers its static actions");
});

test("a palette query with more matches than fit says how many it left out", async function () {
  const { installDom, serialize, dispatch } = await import("../lib/dom-stub.mjs");
  const restore = installDom();
  try {
    const refs = shippedPaletteRefs();
    Object.assign(refs, {
      knownSessionsHolder: { list: [] },
      allToolsHolder: { list: [] },
      board: { cards: [] },
      sessionLabel (s) { return s.title || s.id; },
      runLabel (r) { return r.run_id; }
    });
    // Ten runs whose every node label carries the needle: paletteEntries makes
    // one row per node, so this query matches far more than one screen holds.
    refs.allRunsHolder = {
      list: Array.from({ length: 10 }, (_, n) => ({
        run_id: "run-" + n,
        task: "task " + n,
        nodes: Array.from({ length: 6 }, (_, k) => ({ label: "needle " + n + "-" + k }))
      }))
    };

    // paletteList is a real element from the stub document: it is the one the
    // module appends rendered rows to, and the one this asserts on.
    const els = {
      paletteOpen: stubNode(), paletteList: document.createElement("ul"), palette: stubNode(),
      help: stubNode(), paletteInput: document.createElement("input")
    };

    const { bindPalette } = await import("./palette.js");
    bindPalette({
      VIEWS: ["chat"],
      showView () {},
      el: els,
      refs,
      setRailOpen () {},
      switchSession () {},
      openRun () {},
      renderBoard () {},
      showToolDetail () {},
      setOpenCardId () {}
    });

    // The list re-renders on every keystroke; dispatch the handler the module
    // installed rather than reimplementing the render.
    els.paletteInput.value = "needle";
    dispatch(els.paletteInput, "input", {});

    const out = serialize(els.paletteList);
    assert.match(out, /more match/, "a truncated result must say so, not stop silently");
    assert.match(out, /Type more to narrow the list/, "and say what to do about it");
  } finally {
    restore();
  }
});

test("the palette's no-match note is a note, not a pickable-looking row", async function () {
  const { installDom, serialize, dispatch } = await import("../lib/dom-stub.mjs");
  const restore = installDom();
  try {
    const refs = shippedPaletteRefs();
    Object.assign(refs, {
      knownSessionsHolder: { list: [] },
      allToolsHolder: { list: [] },
      board: { cards: [] },
      sessionLabel (s) { return s.title || s.id; },
      runLabel (r) { return r.run_id; }
    });
    const els = {
      paletteOpen: stubNode(), paletteList: document.createElement("ul"), palette: stubNode(),
      help: stubNode(), paletteInput: document.createElement("input")
    };
    const { bindPalette, PALETTE_ITEM_CLASS } = await import("./palette.js");
    bindPalette({
      VIEWS: ["chat"], showView () {}, el: els, refs,
      setRailOpen () {}, switchSession () {}, openRun () {},
      renderBoard () {}, showToolDetail () {}, setOpenCardId () {}
    });
    els.paletteInput.value = "zzzznotathing";
    dispatch(els.paletteInput, "input", {});
    const out = serialize(els.paletteList);
    assert.match(out, /Nothing matches/);
    assert.equal(
      out.includes('class="' + PALETTE_ITEM_CLASS + '"'), false,
      "the empty row must not wear the pickable option's classes"
    );
  } finally {
    restore();
  }
});
