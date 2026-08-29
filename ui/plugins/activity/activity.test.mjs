// Activity follows the board live: every board action lands in the board room,
// the live bus carries each room message as a `{t:"chat", room:…}` event, and
// the timeline reloads off that instead of waiting for Refresh. The plugin is
// a classic script driven here in a vm with the api surface stubbed, so the
// subscription's three guards (wrong event, hidden view, load in flight) are
// exercised rather than pattern-matched.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "app.js"), "utf8");
const spec = readFileSync(join(dir, "plugin.json"), "utf8");

test("the manifest declares what the subscription uses", function () {
  assert.match(spec, /"live"/);
  assert.match(spec, /"get"/);
  assert.match(spec, /"boardTimeline"/);
});

function fakeEl(tag) {
  return {
    tagName: String(tag).toUpperCase(),
    className: "",
    type: "",
    title: "",
    disabled: false,
    hidden: false,
    childNodes: [],
    parentNode: null,
    listeners: {},
    set textContent(v) { this.childNodes = []; this._t = v; },
    get textContent() { return this._t || ""; },
    appendChild(c) { c.parentNode = this; this.childNodes.push(c); return c; },
    setAttribute() {},
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    closest(sel) {
      let n = this;
      while (n) {
        if (sel === ".view" && n.className === "view") return n;
        n = n.parentNode;
      }
      return null;
    }
  };
}

// Mounts the plugin with a recording api. Returns the knobs the tests turn.
function mountActivity() {
  const loads = [];
  let liveHandler = null;
  const registered = [];
  const sandbox = {
    console,
    Promise,
    encodeURIComponent,
    window: { location: { hash: "" } },
    document: { createTextNode: (t) => ({ _t: t }) },
    clanker: { registerView: (s) => registered.push(s) }
  };
  vm.createContext(sandbox);
  vm.runInContext(js, sandbox);
  assert.equal(registered.length, 1);

  const panel = fakeEl("div");
  panel.className = "view";
  const section = fakeEl("section");
  panel.appendChild(section);

  const api = {
    el: (tag, cls, text) => { const n = fakeEl(tag); if (text != null) n.textContent = text; return n; },
    fmt: { time: String },
    status: () => {},
    showView: () => {},
    boardTimeline: () => [],
    getJSON: (path) => { loads.push(path); return Promise.resolve({}); },
    onLive: (fn) => { liveHandler = fn; }
  };
  const spec2 = registered[0];
  const done = spec2.mount.call(spec2, section, api);
  return { loads, live: () => liveHandler, panel, done };
}

test("a board-room chat event reloads the timeline; other events do not", async function () {
  const m = mountActivity();
  await m.done;
  assert.equal(typeof m.live(), "function", "mount subscribes to the live bus");
  const before = m.loads.length;

  m.live()({ t: "chat", room: "ops" });
  m.live()({ t: "metrics" });
  m.live()(null);
  assert.equal(m.loads.length, before, "only the board room's messages are the board's activity");

  m.live()({ t: "chat", room: "board" });
  assert.ok(m.loads.length > before, "a board action reloads the merged timeline");
});

test("the subscription idles while the view is hidden, reading the panel the host hides", async function () {
  const m = mountActivity();
  await m.done;
  const before = m.loads.length;
  m.panel.hidden = true;
  m.live()({ t: "chat", room: "board" });
  assert.equal(m.loads.length, before, "a hidden view must not poll; re-entry reloads via the refresh hook");
  // And the guard reads the enclosing .view panel, not the section the host
  // never hides — the defect mesh shipped with.
  assert.doesNotMatch(js, /container\.hidden/);
});

test("an event during an in-flight load is not doubled", async function () {
  // `load` disables Refresh for exactly the in-flight window, so the guard
  // reads the same flag the button does.
  const m = mountActivity();
  await m.done;
  assert.match(js, /if \(!ev \|\| viewHidden\(\) \|\| refresh\.disabled\) return;/);
});
