import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "arena.js"), "utf8");

test("a failed match open replaces the transcript, not just the status line", function () {
  assert.match(js, /showLoadError\(byId\("arena-transcript"\)/);
  assert.match(js, /fetchMatch\(id, false\)/);
  const fail = js.slice(js.indexOf("Could not load match:"));
  assert.match(fail, /arena-transcript/);
});

test("the running-match poll is not gated on a live topic nothing publishes", function () {
  // The tick used to open with `if (liveOk()) return;`, copied from the Fleet
  // floor. Fleet is right because `t:"mesh"` is really published; Arena copied
  // the guard without the publisher, and importing arena.js opens the
  // EventSource itself, so liveOk() was true from load and the poll never
  // fetched again. This reads both halves so the pair cannot drift apart
  // again: gate the poll on the stream only once something emits the topic.
  const live = readFileSync(join(dir, "..", "..", "..", "src", "serve", "live.zig"), "utf8");
  const hasPublisher = /publish\(\s*\.arena\b/.test(live);
  const gatesOnLive = /if \(liveOk\(\)\) return;/.test(js);
  assert.equal(
    gatesOnLive && !hasPublisher,
    false,
    "arena.js skips its poll while liveOk() is true, but src/serve/live.zig has no publish(.arena, ...) call, so nothing ever refreshes a running match"
  );
  // Whatever the answer above, the interval itself must still ask quietly.
  assert.match(js, /window\.setInterval\(function \(\) \{\s*fetchMatch\(state\.id, true\);/);
  assert.match(js, /ev\.t !== "arena"/);
});

// The 3D stage's mount/unmount cycle. `ensure3d` is not exported (nothing
// outside the view has any business mounting the stage), and importing
// arena.js under node would drag in the whole /webui module graph, so the
// function is lifted out of the shipped source and run in a vm over stubs.
// `import(` is syntax rather than a call, so it is rewritten to a counter the
// harness owns; everything else runs verbatim.
function ensure3dHarness(stubBehaviour) {
  const from = js.indexOf("function ensure3d() {");
  const to = js.indexOf("\nfunction toggle3d()", from);
  assert.ok(from >= 0 && to > from, "ensure3d is still a top-level function in arena.js");
  const source = js.slice(from, to).replace("import(", "__import(");

  const box = {
    imports: 0, mounts: 0, unmounts: 0, statusText: "", mode3dAfter: null,
    stored: {}
  };
  const stub = {
    S: null,
    mountArena3D: function (host) {
      box.mounts += 1;
      box.lastHost = host;
      if (stubBehaviour === "mount-throws") return Promise.reject(new Error("no WebGL"));
      if (stub.S) return Promise.resolve();
      stub.S = { host: host };
      return Promise.resolve();
    },
    unmountArena3D: function () { box.unmounts += 1; stub.S = null; },
    updateArena3D: function () {}
  };
  const nodes = {};
  const prelude = `
    var arena3d = null;
    var mode3d = true;
    function byId(id) { return (nodes[id] = nodes[id] || { id: id, textContent: "", hidden: false, setAttribute: function () {} }); }
    function syncStageMode() {}
    function renderMatch() {}
    function __import() { box.imports += 1; if (importFails) return Promise.reject(new Error("404")); return Promise.resolve(stub); }
  `;
  const epilogue = `
    globalThis.__run = function () {
      return ensure3d().then(function (a) {
        box.mode3dAfter = mode3d;
        box.statusText = nodes["arena-status"] ? nodes["arena-status"].textContent : "";
        return a;
      });
    };
    globalThis.__unmount = function () { arena3d.unmountArena3D(); };
    globalThis.__memoized = function () { return arena3d; };
  `;
  const context = vm.createContext({
    box, stub, nodes, Promise,
    importFails: stubBehaviour === "import-fails",
    window: { localStorage: { setItem: function (k, v) { box.stored[k] = v; }, getItem: function () { return null; } } }
  });
  vm.runInContext(prelude + source + epilogue, context);
  return { box, stub, context };
}

test("re-entering the arena view after a stop mounts the 3D stage again", async function () {
  // The memo used to be `if (arena3d) return Promise.resolve(arena3d)` over the
  // whole import-and-mount. `unmountArena3D` drops the plugin's scene state but
  // leaves the module object truthy, and `stopArena()` runs on every
  // visibilitychange and on leaving the view — so the second visit took the
  // early return, never mounted, and `updateArena3D` no-opped on a null scene:
  // a blank stage with the 2D canvas hidden and no fallback message.
  const h = ensure3dHarness();
  assert.ok(await h.context.__run());
  assert.equal(h.box.imports, 1);
  assert.equal(h.box.mounts, 1);
  assert.ok(h.stub.S, "first visit leaves a live scene");

  h.context.__unmount();
  assert.equal(h.box.unmounts, 1);
  assert.equal(h.stub.S, null);

  assert.ok(await h.context.__run());
  assert.equal(h.box.imports, 1, "the module itself is fetched once, not again");
  assert.equal(h.box.mounts, 2, "the stage is mounted again after it was torn down");
  assert.ok(h.stub.S, "the second visit has a live scene, not a blank div");
});

test("a mount that fails falls back to the 2D stage and says so", async function () {
  // Not the bug above: the catch was already on the whole chain, so a *first*
  // visit whose mount threw did reach the fallback. It is pinned because the
  // fix moved the mount out of the import's `.then`, and a fallback that only
  // covered the import would leave a silent blank stage on every later visit.
  for (const mode of ["import-fails", "mount-throws"]) {
    const h = ensure3dHarness(mode);
    assert.equal(await h.context.__run(), null, mode + ": ensure3d resolves null");
    assert.equal(h.box.mode3dAfter, false, mode + ": the view drops back to 2D");
    assert.equal(h.box.stored.arena3d, "0", mode + ": the browser preference is cleared");
    assert.match(h.box.statusText, /3D stage unavailable/, mode + ": the status line says why");
  }
});

test("the arena3d plugin's mount is idempotent, which is what lets ensure3d call it every time", function () {
  // The two halves have to stay in step: ensure3d mounts unconditionally, so
  // mountArena3D must keep its own `if (S) return`, and unmountArena3D must
  // keep clearing S. Drift either way is the blank-stage bug again.
  const plugin = readFileSync(join(dir, "..", "..", "plugins", "arena3d", "app.js"), "utf8");
  assert.match(plugin, /export function mountArena3D\(host\) \{\s*if \(S\) return Promise\.resolve\(\);/);
  assert.match(plugin, /export function unmountArena3D\(\)[\s\S]*?\n  S = null;\n\}/);
});
