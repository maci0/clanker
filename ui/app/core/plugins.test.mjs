// The plugin host's three contracts with the page, all of which were broken by
// the same assumption: that a view is opened once and the rail never changes.
//
//  1. `refresh` is the documented re-entry hook, but `viewLoaded` in app.js is
//     set on the first successful load and never cleared, so a view loader was
//     never called a second time and `refresh` was reachable only from the
//     error panel's Retry. Two shipped plugins bolted a MutationObserver on the
//     panel's `hidden` attribute to work around it.
//  2. `api.status` wrote one shared `#webui-plugins-status`, so Health's 1 Hz
//     metrics line buried every other plugin's message and the System panel's
//     own enable/disable confirmations.
//  3. A plugin's tab is placed inside its rail group but registered last, and
//     both `wireTab`'s arrow keys and the tablist's `aria-owns` read
//     registration order, so the two disagreed the moment a plugin existed.
//
// The host is an ES module that imports six siblings and expects a browser, so
// it is run here with the imports stripped and stubbed, over a DOM stub built
// to the shape of the shipped rail (index.html) rather than a flat list.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = join(here, "..");
const hostSrc = readFileSync(join(here, "plugins.js"), "utf8");
const appSrc = readFileSync(join(appRoot, "app.js"), "utf8");
const healthSrc = readFileSync(join(appRoot, "..", "plugins", "health", "app.js"), "utf8");
const officeSrc = readFileSync(join(appRoot, "..", "plugins", "office", "app.js"), "utf8");

/* ---------------------------------------------------------------- DOM stub */

// One compound selector: a tag and any number of #id / .class / [attr] or
// [attr=value] tokens. Enough for every selector the host and wireTab use.
function parseCompound(text) {
  const out = { tag: null, id: null, classes: [], attrs: [] };
  const re = /(^[a-zA-Z][\w-]*)|#([\w-]+)|\.([\w-]+)|\[([\w-]+)(?:=(?:"([^"]*)"|'([^']*)'|([^\]]*)))?\]/g;
  let m;
  while ((m = re.exec(text))) {
    if (m[1]) out.tag = m[1].toUpperCase();
    else if (m[2]) out.id = m[2];
    else if (m[3]) out.classes.push(m[3]);
    else if (m[4]) out.attrs.push([m[4], m[5] ?? m[6] ?? m[7] ?? null]);
  }
  return out;
}

function matchesCompound(node, c) {
  if (node.nodeType !== 1) return false;
  if (c.tag && node.tagName !== c.tag) return false;
  if (c.id && node.id !== c.id) return false;
  for (const cls of c.classes) {
    if (!String(node.className).split(/\s+/).includes(cls)) return false;
  }
  for (const [name, value] of c.attrs) {
    const have = node.getAttribute(name);
    if (have == null) return false;
    if (value != null && have !== value) return false;
  }
  return true;
}

// Descendant combinator only: the last compound must match the node, and the
// earlier ones must match ancestors, in order.
function matchesChain(node, chain) {
  let i = chain.length - 1;
  if (!matchesCompound(node, chain[i])) return false;
  i--;
  let p = node.parentNode;
  while (i >= 0 && p) {
    if (matchesCompound(p, chain[i])) i--;
    p = p.parentNode;
  }
  return i < 0;
}

function chains(selector) {
  return selector.split(",").map((alt) => alt.trim().split(/\s+/).filter(Boolean).map(parseCompound));
}

function descendants(root) {
  const out = [];
  (function walk(n) {
    for (const c of n.childNodes) {
      if (c.nodeType === 1) { out.push(c); walk(c); }
    }
  })(root);
  return out;
}

function makeElement(tag) {
  const node = {
    nodeType: 1,
    tagName: String(tag).toUpperCase(),
    id: "",
    className: "",
    hidden: false,
    tabIndex: 0,
    type: "",
    attributes: {},
    childNodes: [],
    parentNode: null,
    listeners: {},
    focused: 0,
    _text: "",
    get textContent() {
      if (!this.childNodes.length) return this._text;
      return this.childNodes.map((c) => (c.nodeType === 3 ? c._text : c.textContent)).join("");
    },
    set textContent(v) {
      this.childNodes.forEach((c) => { c.parentNode = null; });
      this.childNodes = [];
      this._text = v == null ? "" : String(v);
    },
    appendChild(child) {
      if (this._text) { this.childNodes.push(makeText(this._text)); this._text = ""; }
      child.parentNode = this;
      this.childNodes.push(child);
      return child;
    },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null; },
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    dispatch(type, event) { (this.listeners[type] || []).forEach((fn) => fn(event)); },
    focus() { this.focused++; },
    remove() {
      if (!this.parentNode) return;
      const at = this.parentNode.childNodes.indexOf(this);
      if (at !== -1) this.parentNode.childNodes.splice(at, 1);
      this.parentNode = null;
    },
    closest(selector) {
      const alts = chains(selector).map((c) => c[c.length - 1]);
      let n = this;
      while (n) {
        if (alts.some((c) => matchesCompound(n, c))) return n;
        n = n.parentNode;
      }
      return null;
    },
    querySelectorAll(selector) {
      const pool = descendants(this);
      const out = [];
      for (const c of chains(selector)) {
        for (const n of pool) if (matchesChain(n, c) && !out.includes(n)) out.push(n);
      }
      return out;
    },
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  };
  return node;
}

function makeText(text) {
  return { nodeType: 3, _text: String(text), parentNode: null, get textContent() { return this._text; } };
}

// The shipped rail, to the structure `makeViewShell` walks: a `.rail-places`
// tablist holding Work (an <h2> heading in a <section>) and Watch (a <summary>
// in a <details>), plus a separate `.rail-settings` nav for Set up whose tabs
// are members of the tablist only through `aria-owns`.
const BUILT_INS = [
  ["chat", "Work"], ["kanban", "Work"],
  ["runs", "Watch"], ["fleet", "Watch"], ["arena", "Watch"], ["rooms", "Watch"],
  ["models", "Set up"], ["knowledge", "Set up"], ["prompts", "Set up"],
  ["tools", "Set up"], ["system", "Set up"]
];

function makePage() {
  const root = makeElement("body");
  // The head hangs off the same root the stub's document queries walk, so
  // `document.querySelector` can see what `loadPluginScript` appends there —
  // in a browser <head> is part of the document, and the host's existing-tag
  // check depends on that.
  const head = makeElement("head");
  root.appendChild(head);
  const doc = {
    documentElement: root,
    head: head,
    createElement: makeElement,
    createTextNode: makeText,
    getElementById(id) {
      if (root.id === id) return root;
      return descendants(root).find((n) => n.id === id) || null;
    },
    querySelectorAll(selector) { return root.querySelectorAll(selector); },
    querySelector(selector) { return root.querySelector(selector); }
  };

  const main = makeElement("div");
  main.id = "main";
  root.appendChild(main);

  const rail = makeElement("aside");
  rail.id = "rail";
  root.appendChild(rail);

  const tablist = makeElement("nav");
  tablist.className = "pf-v6-c-nav rail-nav rail-places";
  tablist.setAttribute("role", "tablist");
  rail.appendChild(tablist);

  function group(host, label, heading) {
    const h = makeElement(heading);
    h.className = "pf-v6-c-nav__section-title rail-group";
    h.textContent = label;
    const list = makeElement("ul");
    list.className = "pf-v6-c-nav__list";
    if (heading === "summary") {
      const details = makeElement("details");
      details.appendChild(h);
      const section = makeElement("section");
      section.appendChild(list);
      details.appendChild(section);
      host.appendChild(details);
    } else {
      const section = makeElement("section");
      section.className = "pf-v6-c-nav__section";
      section.appendChild(h);
      section.appendChild(list);
      host.appendChild(section);
    }
    return list;
  }

  const settings = makeElement("nav");
  settings.className = "pf-v6-c-nav rail-nav rail-settings";

  const lists = {
    "Work": group(tablist, "Work", "h2"),
    "Watch": group(tablist, "Watch", "summary")
  };
  rail.appendChild(settings);
  lists["Set up"] = group(settings, "Set up", "summary");

  const tabs = {};
  for (const [view, name] of BUILT_INS) {
    const li = makeElement("li");
    li.className = "pf-v6-c-nav__item";
    const tab = makeElement("button");
    tab.className = "rail-tab";
    tab.id = "tab-" + view;
    tab.setAttribute("role", "tab");
    tab.setAttribute("data-view", view);
    tab.textContent = view;
    li.appendChild(tab);
    lists[name].appendChild(li);
    tabs[view] = tab;
    const panel = makeElement("div");
    panel.id = "view-" + view;
    main.appendChild(panel);
  }
  tablist.setAttribute("aria-owns", BUILT_INS.map((b) => "tab-" + b[0]).join(" "));

  return { doc, root, main, rail, tablist, tabs, views: BUILT_INS.map((b) => b[0]) };
}

/* ------------------------------------------------------- the host, in a vm */

// plugins.js with its six sibling imports stripped and handed in as globals
// instead. `import.meta.url` only ever feeds a `new URL` for a script/css src,
// so it becomes a literal.
function loadHost(page, extras) {
  const src = hostSrc
    .replace(/^import .*;$/gm, "")
    .replace(/\bimport\.meta\.url\b/g, '"https://example.invalid/webui/core/plugins.js"')
    .replace(/^export /gm, "")
    // `typeof` rather than the bare name so a missing export is one failing
    // assertion in the test that needs it, not a ReferenceError in every test.
    + "\n__host = { pluginApi, bindPlugins, loadPluginAssets, renderWebuiPlugins, pluginViews,"
    + " pluginViewShown: typeof pluginViewShown === \"function\" ? pluginViewShown : null };\n";

  const sandbox = {
    __host: null,
    document: page.doc,
    console,
    URL,
    JSON,
    Promise,
    encodeURIComponent,
    setTimeout,
    fetch: () => Promise.reject(new Error("no network in this test")),
    // The stripped imports.
    T: {}, state: () => {}, add: () => {}, effect: () => {},
    showLoadError: (el, msg) => { el.appendChild(makeText(msg)); },
    upgradePfButton: () => {},
    uiConfirm: () => Promise.resolve(false),
    uiPrompt: () => Promise.resolve(null),
    toast: () => {},
    renderMarkdownWithFences: () => makeElement("div"),
    buildCodeBlock: () => makeElement("pre"),
    renderMermaidBlocks: () => {},
    boardTimeline: () => [],
    onLive: () => {},
    icon: () => makeElement("span"),
    searchFoldFind: () => {},
    wireRefresh: () => {},
    ...extras
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);
  return { host: sandbox.__host, sandbox };
}

// A host bound to a fresh page, with the bits of app.js's context the tests
// need. `viewLoaded` mirrors app.js: set once a load has succeeded.
function bootHost(options, extras) {
  const page = makePage();
  const observed = [];
  const { host, sandbox } = loadHost(page, extras);
  const el = { webuiPluginsStatus: makeElement("p"), webuiPlugins: makeElement("div"), webuiPluginsRefresh: null };
  const views = page.views.slice();
  const viewLoaders = {};
  host.bindPlugins({
    VIEWS: views,
    viewLoaders,
    wireTab: () => {},
    showView: () => {},
    el,
    readJson: (r) => r.json(),
    fmtBytes: String, fmtInt: String, fmtCost: String, formatChatTime: String,
    openSession: () => {},
    observeStatus: (node) => observed.push(node),
    ...options
  });
  // What a plugin's app.js is written against: the global the host installs.
  return {
    page, host, el, views, viewLoaders, observed,
    clanker: sandbox.clanker,
    // The re-entry point the page calls on every switch to a loaded view.
    shown(id) {
      assert.equal(typeof host.pluginViewShown, "function", "the host exports no pluginViewShown");
      return host.pluginViewShown(id);
    }
  };
}

/* ------------------------------------------------- 1. refresh is reachable */

test("a plugin's refresh hook is reached on re-entry, and never in the same switch as mount", () => {
  const boot = bootHost();
  const calls = [];
  boot.clanker.registerView({
    id: "demo",
    title: "Demo",
    group: "Watch",
    mount: function (section) { calls.push(["mount", section.tagName]); },
    refresh: function (section) { calls.push(["refresh", section.tagName]); }
  });

  // Before the first open there is nothing mounted, so a switch to the view
  // must not reach refresh: a plugin never sees refresh before mount.
  boot.shown("demo");
  assert.deepEqual(calls, [], "refresh ran before mount");

  // First open: the host calls the loader, which mounts.
  boot.viewLoaders.demo();
  assert.deepEqual(calls, [["mount", "SECTION"]]);

  // Every later switch back. This is the case that never happened: app.js
  // marks the view loaded and never calls the loader again.
  boot.shown("demo");
  boot.shown("demo");
  assert.deepEqual(calls, [["mount", "SECTION"], ["refresh", "SECTION"], ["refresh", "SECTION"]]);
});

test("a refresh assigned from inside mount is the one that gets called", () => {
  // Health and office both do `this.refresh = resume` in mount, so the hook has
  // to be read at call time rather than captured at registration.
  const boot = bootHost();
  const calls = [];
  boot.clanker.registerView({
    id: "swap",
    title: "Swap",
    group: "Work",
    mount: function () { this.refresh = function () { calls.push("resume"); }; },
    refresh: function () { calls.push("placeholder"); }
  });
  boot.viewLoaders.swap();
  boot.shown("swap");
  assert.deepEqual(calls, ["resume"]);
});

test("a plugin with no refresh hook, and an unknown view, are both a no-op", () => {
  const boot = bootHost();
  let mounts = 0;
  boot.clanker.registerView({ id: "bare", title: "Bare", group: "Work", mount: function () { mounts++; } });
  boot.viewLoaders.bare();
  assert.equal(boot.shown("bare"), null);
  assert.equal(boot.shown("chat"), null);
  assert.equal(boot.shown("nope"), null);
  assert.equal(mounts, 1, "re-entry must not mount a second time");
});

test("a throwing refresh is contained in the plugin's own panel", () => {
  const boot = bootHost();
  boot.clanker.registerView({
    id: "boom",
    title: "Boom",
    group: "Work",
    mount: function () {},
    refresh: function () { throw new Error("kaboom"); }
  });
  boot.viewLoaders.boom();
  boot.shown("boom");
  const panel = boot.page.doc.getElementById("view-boom");
  assert.match(panel.textContent, /The Boom plugin failed: kaboom/);
});

test("showView reaches the hook, and only for a view it had already loaded", () => {
  // The behavioural half above proves the host end. This is the page end: the
  // one call site, and the guard that keeps mount and refresh out of the same
  // switch. `viewLoaded[name]` flips inside this function for a loader that
  // resolves synchronously, so the flag has to be read before the load.
  assert.match(appSrc, /pluginViewShown as pluginsViewShown/);
  assert.match(appSrc, /var wasLoaded = !!viewLoaded\[name\];/);
  assert.match(appSrc, /if \(wasLoaded\) pluginsViewShown\(name\);/);
  const wasLoadedAt = appSrc.indexOf("var wasLoaded = !!viewLoaded[name];");
  const loadAt = appSrc.indexOf("if (!viewLoaded[name] && viewLoaders[name]) {");
  const callAt = appSrc.indexOf("if (wasLoaded) pluginsViewShown(name);");
  assert.ok(wasLoadedAt !== -1 && loadAt !== -1 && callAt !== -1);
  assert.ok(wasLoadedAt < loadAt, "wasLoaded must be read before the load can set viewLoaded");
  assert.ok(loadAt < callAt, "the hook is for a switch, so it runs after the load branch");
});

test("the two plugins that worked around the missing hook no longer watch the panel", () => {
  // Both watched their panel's `hidden` attribute because the hook never fired.
  // Leaving the observer in place alongside a working hook costs a second
  // /api/metrics read (health) and a second poll (office) on every re-entry.
  for (const [name, src] of [["health", healthSrc], ["office", officeSrc]]) {
    assert.doesNotMatch(src, /new MutationObserver/, name + " still works around the hook");
    assert.match(src, /this\.refresh = resume;/, name + " must still offer a resume hook");
  }
});

/* -------------------------------------------- 2. one live region per plugin */

test("each plugin announces into its own live region, not one shared node", () => {
  const boot = bootHost();
  const specs = {};
  for (const id of ["alpha", "beta"]) {
    specs[id] = { id, title: id, group: "Watch", mount: function () {} };
    boot.clanker.registerView(specs[id]);
  }
  const alpha = boot.host.pluginApi(specs.alpha);
  const beta = boot.host.pluginApi(specs.beta);

  alpha.status("Alpha is busy.");
  beta.status("Beta is busy.");

  assert.equal(boot.page.doc.getElementById("plugin-status-alpha").textContent, "Alpha is busy.");
  assert.equal(boot.page.doc.getElementById("plugin-status-beta").textContent, "Beta is busy.");
  // The System panel's line is the loader's alone now, so an enable
  // confirmation cannot be overwritten by a plugin on a timer.
  assert.equal(boot.el.webuiPluginsStatus.textContent, "");
});

test("a plugin's live region is a polite status node inside that plugin's panel", () => {
  const boot = bootHost();
  boot.clanker.registerView({ id: "gamma", title: "Gamma", group: "Work", mount: function () {} });
  const live = boot.page.doc.getElementById("plugin-status-gamma");
  assert.equal(live.getAttribute("role"), "status");
  assert.equal(live.getAttribute("aria-live"), "polite");
  assert.equal(live.className, "sr-only");
  assert.equal(live.closest("#view-gamma").id, "view-gamma");
  // And it joins the page's status-to-toast mirror, so the message is seen and
  // not only announced.
  assert.ok(boot.observed.includes(live));
});

test("the same line twice running is one announcement", () => {
  const boot = bootHost();
  const spec = { id: "delta", title: "Delta", group: "Work", mount: function () {} };
  boot.clanker.registerView(spec);
  const api = boot.host.pluginApi(spec);
  const live = boot.page.doc.getElementById("plugin-status-delta");
  let writes = 0;
  Object.defineProperty(live, "textContent", {
    get() { return this.__t || ""; },
    set(v) { writes++; this.__t = v; }
  });
  api.status("Loading…");
  api.status("Loading…");
  api.status("Done.");
  assert.equal(writes, 2);
});

test("a status call with no panel behind it still lands somewhere", () => {
  // `module`-shaped plugins and a spec with no id have no view chrome; the
  // write must not throw on a missing node.
  const boot = bootHost();
  boot.host.pluginApi({ id: "never-registered" }).status("Orphan.");
  assert.equal(boot.el.webuiPluginsStatus.textContent, "Orphan.");
  boot.host.pluginApi(null).status("No spec.");
  assert.equal(boot.el.webuiPluginsStatus.textContent, "No spec.");
});

test("Health announces a read somebody asked for, never the 1 Hz live sample", () => {
  // /api/metrics rides the live bus at 1 Hz. Writing every sample to the status
  // line gave a screen reader a fresh polite announcement every second, and the
  // page's status mirror a fresh toast with it, for as long as the tab was open.
  assert.match(healthSrc, /function applySample\(d, announce\)/);
  assert.match(healthSrc, /if \(announce\) \{\s*\n\s*api\.status\("Health: "/);
  assert.match(healthSrc, /applySample\(ev, false\)/);
  assert.match(healthSrc, /return applySample\(d, true\);/);
  assert.doesNotMatch(
    healthSrc, /\.then\(applySample\)/,
    "passing applySample straight to then hands the promise index as `announce`"
  );
});

/* ------------------------------------------ 3. rail order, not push order */

// `wireTab` and `railOrder` lifted out of app.js and run against a rail that
// has a plugin tab in the middle of it, which is what `makeViewShell` builds.
function liftTabWiring(page, views, onShow) {
  const sandbox = {
    document: page.doc,
    VIEWS: views,
    showView: (name) => onShow.push(name),
    console
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  for (const name of ["railOrder", "wireTab"]) {
    const m = appSrc.match(new RegExp("\\nfunction " + name + "\\(([^)]*)\\) \\{\\n[\\s\\S]*?\\n\\}\\n"));
    if (m) vm.runInContext(m[0], sandbox);
  }
  assert.equal(typeof sandbox.wireTab, "function", "wireTab not found in app.js");
  return sandbox;
}

function press(tab, key) {
  let prevented = 0;
  tab.dispatch("keydown", { key, preventDefault: () => { prevented++; } });
  return prevented;
}

test("arrow keys on the rail follow the rail, not the order plugins registered in", () => {
  const boot = bootHost();
  const shown = [];
  const sandbox = liftTabWiring(boot.page, boot.views, shown);
  // The page wires the eleven built-ins by their index in VIEWS.
  boot.views.slice().forEach((v, i) => sandbox.wireTab(boot.page.tabs[v], i));

  // A Work group plugin: its tab lands after Kanban, and it is pushed onto
  // VIEWS last. `files` is the shipped case.
  boot.clanker.registerView({ id: "files", title: "Files", group: "Work", mount: function () {} });
  const tab = boot.page.doc.getElementById("tab-files");
  assert.equal(boot.views[boot.views.length - 1], "files", "registration appends");
  sandbox.wireTab(tab, boot.views.length - 1);

  assert.equal(press(tab, "ArrowUp"), 1);
  assert.equal(shown.pop(), "kanban", "ArrowUp from a Work plugin used to land on System");
  press(tab, "ArrowDown");
  assert.equal(shown.pop(), "runs");
  press(tab, "End");
  assert.equal(shown.pop(), "system", "End used to select the last-registered plugin");
  press(tab, "Home");
  assert.equal(shown.pop(), "chat");

  // The tab either side of the plugin has to agree, or the rail has a hole.
  press(boot.page.tabs.kanban, "ArrowDown");
  assert.equal(shown.pop(), "files");
  press(boot.page.tabs.runs, "ArrowUp");
  assert.equal(shown.pop(), "files");
  // And the ends still wrap.
  press(boot.page.tabs.chat, "ArrowUp");
  assert.equal(shown.pop(), "system");
  press(boot.page.tabs.system, "ArrowDown");
  assert.equal(shown.pop(), "chat");

  // And the order the moves are read off, named, so the two cannot drift.
  assert.equal(typeof sandbox.railOrder, "function", "app.js has no railOrder");
  assert.deepEqual(
    // Array.from because the vm builds it with the sandbox realm's Array.
    Array.from(sandbox.railOrder()),
    ["chat", "kanban", "files", "runs", "fleet", "arena", "rooms",
     "models", "knowledge", "prompts", "tools", "system"],
    "the rail's order is not VIEWS' order once a plugin exists"
  );
});

test("a key the tablist does not own is left alone", () => {
  const boot = bootHost();
  const shown = [];
  const sandbox = liftTabWiring(boot.page, boot.views, shown);
  sandbox.wireTab(boot.page.tabs.chat, 0);
  assert.equal(press(boot.page.tabs.chat, "PageDown"), 0);
  assert.deepEqual(shown, []);
});

test("aria-owns is rebuilt in rail order, so a screen reader reads the rail", () => {
  const boot = bootHost();
  boot.clanker.registerView({ id: "files", title: "Files", group: "Work", mount: function () {} });
  boot.clanker.registerView({ id: "mesh", title: "Mesh", group: "Watch", mount: function () {} });
  assert.deepEqual(
    boot.page.tablist.getAttribute("aria-owns").split(" "),
    ["tab-chat", "tab-kanban", "tab-files", "tab-runs", "tab-fleet", "tab-arena",
     "tab-rooms", "tab-mesh", "tab-models", "tab-knowledge", "tab-prompts",
     "tab-tools", "tab-system"],
    "appending the new id put a Work group plugin after System"
  );
});

/* --------------------------------------- 4. a failed script load can retry */

test("Retry after a failed script load fetches the script again", async () => {
  // The error panel's retry resets the promise cache and calls the loader
  // again, but the failed <script> tag used to stay in the head, where the
  // loader's existing-tag check found it and resolved true without a fetch:
  // Retry could never succeed for a deferred plugin whose script had 404ed.
  const retries = [];
  const boot = bootHost({}, {
    showLoadError: (el, msg, retryFn) => {
      el.appendChild(makeText(msg));
      retries.push(retryFn);
    }
  });
  boot.host.loadPluginAssets([{ name: "ghost", title: "Ghost", group: "Watch", enabled: true, has_css: false }]);
  assert.equal(typeof boot.viewLoaders.ghost, "function", "a deferred plugin gets a loader");

  const first = boot.viewLoaders.ghost();
  const s1 = boot.page.doc.head.querySelector('script[data-plugin="ghost"]');
  assert.ok(s1, "the loader injects a script tag");
  s1.onerror();
  await first;
  assert.equal(
    boot.page.doc.head.querySelector('script[data-plugin="ghost"]'), null,
    "a failed script tag must not stay in the head"
  );
  const panel = boot.page.doc.getElementById("view-ghost");
  assert.match(panel.textContent, /Could not load the Ghost plugin/);
  assert.equal(retries.length, 1, "the failure offers a Retry");

  const second = retries[0]();
  const s2 = boot.page.doc.head.querySelector('script[data-plugin="ghost"]');
  assert.ok(s2 && s2 !== s1, "Retry must inject a fresh script tag, not find the dead one");
  // This time the script arrives and registers, the way app.js running would.
  let mounts = 0;
  boot.clanker.registerView({ id: "ghost", title: "Ghost", group: "Watch", mount: function () { mounts++; } });
  s2.onload();
  await second;
  assert.equal(mounts, 1, "the retried load mounts the plugin");
});

/* --------------------------------------------- 5. a throwing boot is named */

test("a throwing boot lands in the loader's status line, not an empty catch", () => {
  // `boot` runs at page load with no view panel behind it, so mount's
  // containment cannot catch it; it used to vanish into `catch (e) {}` and an
  // eager plugin's dock was simply absent with nothing anywhere saying why.
  const boot = bootHost();
  const calls = [];
  boot.clanker.registerView({
    id: "dock",
    title: "Dock",
    group: "Watch",
    mount: function () {},
    boot: function (api) { calls.push(typeof api.getJSON); throw new Error("no audio"); }
  });
  assert.equal(calls.length, 1, "boot still runs, and is handed the api surface");
  assert.equal(calls[0], "function");
  assert.equal(
    boot.el.webuiPluginsStatus.textContent,
    "The Dock plugin failed to start: no audio"
  );

  // And the deferred-shell path reports through the same line: the shell
  // exists before the script runs, so registerView takes the other branch.
  boot.host.loadPluginAssets([{ name: "lazy", title: "Lazy", group: "Watch", enabled: true, has_css: false }]);
  boot.clanker.registerView({
    id: "lazy",
    title: "Lazy",
    group: "Watch",
    mount: function () {},
    boot: function () { throw new Error("late throw"); }
  });
  assert.equal(
    boot.el.webuiPluginsStatus.textContent,
    "The Lazy plugin failed to start: late throw"
  );

  // Control: a healthy boot says nothing.
  boot.el.webuiPluginsStatus.textContent = "";
  boot.clanker.registerView({ id: "fine", title: "Fine", group: "Watch", mount: function () {}, boot: function () {} });
  assert.equal(boot.el.webuiPluginsStatus.textContent, "");
});
