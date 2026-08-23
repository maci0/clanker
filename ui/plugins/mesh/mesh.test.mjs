import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "app.js"), "utf8");
const css = readFileSync(join(dir, "app.css"), "utf8");
const spec = readFileSync(join(dir, "plugin.json"), "utf8");

test("Mesh is a Watch plugin over the mesh HTTP control plane", function () {
  assert.match(spec, /"name": "mesh"/);
  assert.match(spec, /"group": "Watch"/);
  assert.match(spec, /"toast"/);
  assert.match(spec, /"prompt"/);
  assert.match(js, /clanker\.registerView/);
  assert.match(js, /\/api\/mesh\/status/);
  assert.match(js, /\/api\/mesh\/join/);
  assert.match(js, /\/api\/mesh\/leave/);
  assert.match(js, /\/api\/mesh\/pending/);
  assert.match(js, /Admit/);
  assert.match(js, /Deny/);
});

test("mesh-off and empty member lists are visible, not only a status line", function () {
  assert.match(js, /Mesh is off\. Set modules\.mesh = true/);
  assert.match(js, /No members\. Join a listen address below/);
  assert.match(js, /No pending joins/);
  assert.match(js, /Try again/);
});

test("self-leave asks before dropping every member", function () {
  assert.match(js, /api\.confirm\("Leave the mesh\?/);
  assert.match(js, /leaveSelf\.hidden = !list\.length/);
});

test("identity facts include a copyable listen address", function () {
  assert.match(js, /copyListen/);
  assert.match(js, /This instance listens on /);
  assert.match(js, /mesh-facts/);
  assert.match(js, /api\.prompt\("Listen address"/);
});

test("join field stays 16px on a phone so iOS does not zoom", function () {
  assert.match(css, /@media \(max-width: 40rem\) \{[\s\S]*\.mesh-join-form input \{ font-size: 16px; \}/);
});

// The poll idles on a hidden view — reading the attribute the host really sets.
//
// `mount` is handed the inner <section>; `hidden` is toggled on the enclosing
// `.view` panel. `container.hidden` on the section is therefore false forever,
// so the three guards that read it were guards over nothing and opening Mesh
// once left `/api/mesh/status` + `/api/mesh/pending` firing every 4s for the
// life of the tab. Both halves are read here so they cannot drift apart again.
test("the visibility guard reads the panel the host hides, not the section", function () {
  const loader = readFileSync(join(dir, "..", "..", "app", "core", "plugins.js"), "utf8");
  const host = readFileSync(join(dir, "..", "..", "app", "app.js"), "utf8");

  // What the host hands mount, and what the host hides.
  assert.match(loader, /spec\.mount\.call\(spec, section,/);
  assert.match(loader, /panel\.className = "view"/);
  assert.match(host, /panel\.hidden = !on/);

  assert.doesNotMatch(
    js, /container\.hidden/,
    "container is the section; the host never sets hidden on it, so this reads false forever"
  );
  assert.match(js, /function viewHidden\(\) \{/);
  assert.match(js, /container\.closest\(".view"\)/);
  // Every one of the three consumers uses it.
  assert.match(js, /if \(!ev \|\| viewHidden\(\)\) return;/);
  assert.match(js, /if \(viewHidden\(\) \|\| state\.busy\) return;/);
  assert.match(js, /if \(viewHidden\(\) \|\| !state\.pending\.length\) return;/);
});

// And the same thing behaviourally: the shipped `viewHidden` lifted out and run
// against the production shape — a visible <section> inside a hidden `.view`
// panel, which is exactly the state `container.hidden` used to read as "shown".
test("viewHidden sees a hidden panel through a section that is not hidden", function () {
  const from = js.indexOf("function viewHidden() {");
  const to = js.indexOf("api.onLive(", from);
  assert.ok(from >= 0 && to > from);

  function shape(panelHidden) {
    const panel = { hidden: panelHidden, className: "view" };
    return { hidden: false, closest: (sel) => (sel === ".view" ? panel : null) };
  }
  for (const [panelHidden, expected] of [[true, true], [false, false]]) {
    const ctx = { container: shape(panelHidden) };
    vm.createContext(ctx);
    vm.runInContext(js.slice(from, to) + "\nvar out = viewHidden();", ctx);
    assert.equal(ctx.out, expected);
  }
  // A container with no enclosing panel is not a reason to stop polling.
  const orphan = { container: { hidden: false, closest: () => null } };
  vm.createContext(orphan);
  vm.runInContext(js.slice(from, to) + "\nvar out = viewHidden();", orphan);
  assert.equal(orphan.out, false);
});
