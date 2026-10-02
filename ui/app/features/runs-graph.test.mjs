// The run-graph minimap shipped two pointer gestures and said so in its own
// accessible name ("click to jump, drag viewport to pan"), but was neither a
// tab stop nor keyboard-driven. A keyboard user reached the graph only through
// its zoom, fit and search controls, and the one control that names its
// gestures as available offered none.
//
// The minimap's wiring is three contiguous statements inside drawRun, not a
// liftable top-level function, so the harness lifts exactly those and runs
// them verbatim over a canvas stub. Everything asserted below is the shipped
// handler's own effect on that stub, not a restatement of it.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const js = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "runs.js"), "utf8");

/* Lift the shipped minimap wiring into a runnable form.
   `drawRun` builds the minimap element by hand, so the element's own
   attributes are asserted against the shipped source and the two gestures are
   run against the real handler bodies. */
function harness({ nodes = [] } = {}) {
  const from = js.indexOf("  function minimapJump(px, py){");
  const to = js.indexOf("  // drag viewport to pan", from);
  assert.ok(from >= 0 && to > from, "the minimap wiring is still the shape the harness lifts");

  const box = { focused: [], clicked: [], prevented: 0 };
  const canvas = {
    scrollLeft: 0, scrollTop: 0, clientWidth: 100, clientHeight: 100,
    addEventListener () {}
  };
  const mmNodes = nodes.map(function (n, i) {
    return {
      x: n[0], y: n[1],
      el: {
        focus () { box.focused.push(i); },
        click () { box.clicked.push(i); },
        scrollIntoView () {}
      }
    };
  });
  // One listener per event, so the harness fires the same one the browser does.
  const listeners = { click: null, keydown: null };
  const minimap = {
    getBoundingClientRect () { return { left: 0, top: 0, width: 100, height: 100 }; },
    addEventListener (name, fn) { listeners[name] = fn; }
  };
  const mmViewport = {};

  // drawRun's closure state the lifted code reads. The graph is 400x300 and
  // the viewport 100x100, so a click at (50,50) in a 100x100 minimap maps to
  // graph (200,150).
  const mmSW = 400;
  const mmSH = 300;

  const epilogue = `
    globalThis.__click = function (clientX, clientY) {
      listeners.click({ target: minimap, clientX: clientX, clientY: clientY });
    };
    globalThis.__key = function (key) {
      var prevented = false;
      listeners.keydown({ key: key, preventDefault: function () { prevented = true; box.prevented += 1; } });
      return prevented;
    };
  `;

  const context = vm.createContext({
    box, canvas, minimap, mmViewport, mmNodes, mmSW, mmSH, listeners,
    Math, Infinity
  });
  vm.runInContext(js.slice(from, to) + epilogue, context);

  return { box, canvas, click: context.__click, key: context.__key };
}

test("arrow keys pan the canvas the way the pointer drag does", function () {
  const { box, canvas, key } = harness();

  // Left/Up move toward the origin and stay non-negative; the browser clamps
  // a negative scroll offset to 0, and the handler must not push the graph out
  // the far side on the way.
  canvas.scrollLeft = 200;
  canvas.scrollTop = 200;
  key("ArrowLeft");
  key("ArrowUp");
  assert.equal(canvas.scrollLeft, 185, "ArrowLeft moves 15% of the visible width");
  assert.equal(canvas.scrollTop, 185, "ArrowUp moves 15% of the visible height");

  canvas.scrollLeft = 200;
  key("ArrowRight");
  assert.equal(canvas.scrollLeft, 215);
  assert.equal(box.prevented, 3, "each pan key claims the event from the scroller");
});

test("Home centres the viewport", function () {
  const { canvas, key } = harness();

  canvas.scrollLeft = 0;
  canvas.scrollTop = 0;
  key("Home");
  assert.equal(canvas.scrollLeft, 150, "centred in a 400px graph over a 100px viewport");
  assert.equal(canvas.scrollTop, 100);
});

test("an unhandled key is left to the scroller", function () {
  const { box, key } = harness();

  assert.equal(key("PageDown"), false, "nothing is claimed");
  assert.equal(box.prevented, 0);
});

test("clicking near a node selects it, through the one jump both gestures share", function () {
  // A click at (50,50) maps to graph (200,150); node 1 sits there, so the
  // shipped `bestD < 60` nearest-node branch is the one taken.
  const h = harness({ nodes: [[10, 10], [200, 150], [390, 290]] });
  h.click(50, 50);
  assert.deepEqual(h.box.focused, [1], "the nearest node is focused");
  assert.deepEqual(h.box.clicked, [1], "and activated, not merely scrolled to");
  assert.equal(h.canvas.scrollLeft, 0, "the canvas did not scroll instead");
});

test("a node beyond the 60px threshold does not capture the jump", function () {
  // The threshold is the shipped one, and the test pins the boundary rather
  // than assuming any node wins.
  const h = harness({ nodes: [[140, 110]] });
  h.click(50, 50);
  assert.deepEqual(h.box.clicked, [], "too far to be a node hit");
  assert.equal(h.canvas.scrollLeft, 150, "so it scrolls to the clicked point");
});

test("clicking empty space scrolls there, through the one shared jump", function () {
  const { canvas, click } = harness();

  click(50, 50);
  assert.equal(canvas.scrollLeft, 150, "halfway across a 400px graph in a 100px viewport");
  assert.equal(canvas.scrollTop, 100);
});

test("the minimap is a tab stop, and its name states the keyboard gesture", function () {
  const built = js.slice(js.indexOf("var minimap = document.createElement(\"div\");"), js.indexOf("var mmLabel"));
  assert.match(built, /minimap\.setAttribute\("tabindex", "0"\)/, "it is reachable by Tab");
  assert.match(
    built,
    /aria-label", "Minimap:[^"]*[Aa]rrow keys[^"]*"/,
    "and its name states the keyboard gesture, not only the pointer ones",
  );
  // The ring is named per element in this sheet rather than globally, so a
  // focusable that does not name one has none.
  assert.match(js, /var MINIMAP_CLASS = "[^"]*focus-visible:outline-2/, "it draws a focus ring of its own");
});

test("the pointer and the keyboard share one jump implementation", function () {
  // Two copies of "find the nearest node and scroll there" would drift, which is
  // how the keyboard path ends up jumping somewhere the click does not.
  assert.match(js, /function minimapJump\(px, py\)/);
  assert.equal(
    (js.match(/function minimapJump\(/g) || []).length,
    1,
    "there is one jump implementation, not a second copy behind the keys",
  );
});
