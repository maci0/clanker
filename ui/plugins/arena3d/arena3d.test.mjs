import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { strict as assert } from "node:assert";
import { test } from "node:test";

// Source-pinned, like the other plugin suites here: the module imports three
// and /webui/*, so it cannot be loaded in node.
const here = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(here, "app.js"), "utf8");

test("the 3D stage re-measures when its host resizes", () => {
  // The canvas element is CSS width:100%, so the *element* followed the host
  // while the backing store, the camera aspect and the projection stayed
  // frozen at mount. Narrowing the window or turning a phone sideways
  // stretched the whole stage, with nothing on screen to say so. The host is
  // now watched, and the teardown releases the watch.
  assert.match(js, /new ResizeObserver\(/);
  assert.match(js, /camera\.aspect = w \/ h/);
  assert.match(js, /camera\.updateProjectionMatrix\(\)/);
  assert.match(js, /S\.observer\.disconnect\(\)/);

  const from = js.indexOf("function resize()");
  const to = js.indexOf("function track(");
  assert.ok(from >= 0 && to > from, "resize() is still there");
  const body = js.slice(from, to);
  assert.match(body, /renderer\.setSize\(w, h\)/, "the backing store follows too");
  assert.match(body, /if \(!S\) return;/, "a resize after unmount is a no-op, not a throw");
});

test("the 3D stage is reachable by the pointer", () => {
  // #arena-stage is a decorative overlay with pointer-events-none, so the 2D
  // canvas under it must stay uninteractive -- but this host inherits it, and
  // nothing put the events back, so every handler bindPointer() attaches (drag
  // to orbit, wheel to zoom, the grab cursor) was dead: the stage could only be
  // watched auto-orbiting, never turned.
  const from = js.indexOf("function bindPointer()");
  const body = js.slice(from, js.indexOf("/* ---------------------------------------------------------------- theming */", from));
  assert.match(body, /pointerEvents = "auto"/,
    "the interactive stage re-enables its own pointer events");
  assert.match(body, /addEventListener\("pointerdown"/);
  assert.match(body, /addEventListener\("wheel"/);
});

test("the stage unmounts without a live observer", () => {
  const from = js.indexOf("export function unmountArena3D(");
  const body = js.slice(from, js.indexOf("S = null;", from));
  assert.match(body, /if \(S\.observer\) \{ S\.observer\.disconnect\(\); S\.observer = null; \}/);
  assert.match(body, /if \(S\.onResize\) \{ window\.removeEventListener\("resize", S\.onResize\)/);
});

