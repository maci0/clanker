// Vanilla, no bundler. Web UI plugin host — view registration + asset loading.
import { RAIL_TAB_CLASS, T, add, bind, effect, requireText, showLoadError, skeletonRows, state, toast, UI, uiConfirm, uiPrompt, runDetail, toolRow } from "./ui.js";
import { renderMarkdownWithFences, buildCodeBlock, renderMermaidBlocks } from "../lib/markdown.js";
import { boardTimeline } from "../lib/board.js";
import { liveOk, makeLineSplitter, onLive, pumpInto } from "./stream.js";
import { closeOverlay, openOverlay, trapOverlayTab } from "./overlay.js";
import { copyText, loadD3, paintTomlInto, reducedMotion, scrollTo } from "./vendor.js";
import { goalFields, goalPinnedColumn, goalSortKey, goalStatusLabel, goalWorktreeTitle } from "./goals.js";
import { runLabel } from "./labels.js";
import { decorateRailTab, icon } from "./icons.js";
import {
  clip, cssColorAlpha, cssColorMix, escapeHtml, fmtDeadline,
  fmtMs, fmtPct, fmtUnit, fmtAgo, fmtUsd, peerColor, plural,
  providerUnusableReason, searchFoldFind, searchFold, showLoading, themeToken, wireRefresh
} from "./utils.js";

// A plugin that still hands a raw <button> through api.ui.button gets the
// plate variant when it named none. primary, danger and the rail/chip
// classes are left alone.
var BUTTON_VARIANTS = ["primary", "secondary", "danger", "chip-btn", "scroll-bottom", "rail-new"];
function stampButtonVariant(el) {
  if (!el || el.tagName !== "BUTTON") return el;
  for (var i = 0; i < BUTTON_VARIANTS.length; i++) {
    if (el.classList.contains(BUTTON_VARIANTS[i])) return el;
  }
  el.classList.add("secondary");
  return el;
}

export var pluginViews = {};

var _VIEWS = null;
var _viewLoaders = null;
var _wireTab = null;
var _showView = null;
var _el = null;
var _readJson = null;
var _fmtBytes = null;
var _fmtInt = null;
var _fmtCost = null;
var _formatChatTime = null;
var _openSession = null;
var _observeStatus = null;

/* So a plugin filter matches what the host filters match, and a plugin
   name sort collates instead of comparing code points. `ms`, `pct`, `usd`,
   `deadline`, `runLabel` and `providerReason` are here for the same reason
   the first six are: a built-in view that formats a run row, a percent, a
   cost or a goal would otherwise carry a second copy of one of them. */
function fmt() {
  return {
    bytes: _fmtBytes, int: _fmtInt, cost: _fmtCost, time: _formatChatTime,
    ms: fmtMs, pct: fmtPct, usd: fmtUsd, deadline: fmtDeadline,
    unit: fmtUnit, ago: fmtAgo, plural: plural,
    runLabel: runLabel,
    providerReason: providerUnusableReason,
    fold: searchFold,
    compare: function (a, b) { return String(a).localeCompare(String(b), undefined, { sensitivity: "base" }); }
  };
}

/* The System panel's own line, for the loader's messages only. Guarded because
   the panel is not on the page in every embedding of the app. */
function hostStatus(message) {
  if (_el && _el.webuiPluginsStatus) _el.webuiPluginsStatus.textContent = message;
}

/* One live region per plugin view, keyed by view id and built with the view's
   chrome. A single shared region meant every plugin, plus the loader's own
   enable/disable/failure lines, wrote the same node: Health announces off the
   1 Hz metrics bus, so an enable confirmation was overwritten inside a second
   and a screen reader heard Health's counters instead. */
var pluginStatusNodes = {};

function readJsonResponse(r) {
  return r.json().then(function (d) {
    if (!r.ok) throw new Error(d.error || "HTTP " + r.status);
    return d;
  });
}

function pluginStorage(spec) {
  var prefix = "clanker.plugin." + ((spec && spec.id) ? spec.id : "unknown") + ".";
  return {
    get: function (key) {
      try { return window.localStorage.getItem(prefix + key); } catch (e) { return null; }
    },
    set: function (key, value) {
      try { window.localStorage.setItem(prefix + key, value); } catch (e) {}
    },
    remove: function (key) {
      try { window.localStorage.removeItem(prefix + key); } catch (e) {}
    }
  };
}

/* The component kit (core/kit.js) is handed to a plugin and never used by this
   host, and every plugin loads lazily, so the module is imported on the first
   plugin load rather than sitting in the page's eager graph: its variant tables
   and shared surfaces cost ~1.8K gz there for nothing on a chat-only visit.
   The loader resolves before any plugin script is injected (loadPluginAssets),
   so a plugin that reaches for api.kit finds it. */
var kitModule = null;
/* A host that evaluates this file without a module loader (the suite in
   ui/app/core/plugins.test.mjs strips the imports and hands them in) replaces
   the loader through `__kitLoader`; in the browser the import is the real one. */
var kitLoader = (typeof globalThis !== "undefined" && typeof globalThis.__kitLoader === "function")
  ? globalThis.__kitLoader
  : function () { return import("./kit.js"); };
function loadKit() {
  if (kitModule) return Promise.resolve(kitModule);
  return kitLoader().then(function (m) { kitModule = m; return m; });
}

export function pluginApi(spec) {
  return {
    getJSON: function (path) {
      return fetch(path).then(readJsonResponse);
    },
    postJSON: function (path, body) {
      return fetch(path, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body == null ? {} : body)
      }).then(readJsonResponse);
    },
    // DELETE without a body is the common shape (drop a resource by id);
    // when a body is passed it is JSON, matching postJSON.
    del: function (path, body) {
      var init = { method: "DELETE" };
      if (body != null) {
        init.headers = { "Content-Type": "application/json" };
        init.body = JSON.stringify(body);
      }
      return fetch(path, init).then(readJsonResponse);
    },
    onLive: onLive,
    emit: function (data) {
      return fetch("/api/live", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ from: (spec && spec.id) ? spec.id : "unknown", data: data == null ? {} : data })
      }).then(readJsonResponse);
    },
    confirm: uiConfirm,
    prompt: uiPrompt,
    toast: toast,
    workspace: function () { return window.clankerWorkspace || ""; },
    icon: icon,
    storage: pluginStorage(spec),
    openSession: function (id, jump) {
      if (_openSession) _openSession(id, jump);
    },
    foldFind: searchFoldFind,
    el: function (tag, className, text) {
      var node = document.createElement(tag);
      if (className) node.className = className;
      if (text != null) node.textContent = text;
      return node;
    },
    status: function (message) {
      var node = (spec && spec.id) ? pluginStatusNodes[spec.id] : null;
      if (!node) { hostStatus(message); return; }
      // The same line written twice running is one announcement, not two.
      if (node.textContent === message) return;
      node.textContent = message;
    },
    fmt: fmt(),
    // The component kit (core/kit.js): variant tables and shared surfaces, so
    // an addon styles itself the way the page does instead of shipping a sheet.
    kit: kitModule,
    // Kept under the old name so plugins written against the VanJS-era API
    // keep working: same tags/state/add semantics, now signals-backed.
    van: { tags: T, state: state, add: add, derive: effect, bind: bind },
    // The page's own chrome (`core/ui.js`), which a built-in view imports by
    // name: the empty/loading plate, the skeleton rows a list shows before its
    // first answer, the run and tool rows, the button upgrade, the refresh
    // wiring, the required-field refusal, and `UI`, the small kit of element
    // builders. Without these an addon view that showed a run list or a
    // settings form could not be written, only approximated.
    ui: {
      loadError: showLoadError,
      loading: showLoading,
      skeletonRows: skeletonRows,
      toolRow: toolRow,
      runDetail: runDetail,
      button: stampButtonVariant,
      refresh: wireRefresh,
      requireText: requireText,
      kit: UI
    },
    // A modal dialog with focus handling (`core/overlay.js`). A view that
    // confirms a destructive action or edits a record needs one, and building
    // a second untrapped dialog in a plugin is how a page grows two
    // incompatible modal behaviours.
    overlay: { open: openOverlay, close: closeOverlay, trapTab: trapOverlayTab },
    // A streaming read over `fetch`, the same three the chat composer uses
    // (`core/stream.js`): split a body into whole lines, pump one into a
    // container, and read whether the live bus is currently up.
    stream: { lines: makeLineSplitter, pump: pumpInto, ok: liveOk },
    // Text shaping shared with the transcript rows.
    text: { clip: clip, escape: escapeHtml },
    // Page-level DOM helpers (`core/vendor.js`) and the theme's colour
    // helpers, so a view painting a peer or a themed chart reads the same
    // tokens the page does instead of hardcoding a palette.
    dom: {
      copy: copyText, scrollTo: scrollTo, toml: paintTomlInto, d3: loadD3,
      reducedMotion: reducedMotion
    },
    color: {
      peer: peerColor, token: themeToken, alpha: cssColorAlpha, mix: cssColorMix
    },
    // Goal row helpers (`core/goals.js`), so a view listing goals reads one
    // implementation of the sort key, the fields and the status label.
    goals: {
      sortKey: goalSortKey, fields: goalFields, statusLabel: goalStatusLabel,
      worktreeTitle: goalWorktreeTitle, pinnedColumn: goalPinnedColumn
    },
    // Component views: Preact + htm, vendored, put on window by preact-boot.
    preact: window.preact,
    html: window.html,
    signals: window.signals,
    showView: function (id) { _showView(id, false); },
    // What the board recorded happening, as one dated timeline over the card
    // logs and the board room's action messages (`lib/board.js`). Here rather
    // than in the plugin because reading either feed alone is wrong in a way
    // that is not obvious: only the `log` action writes a card's log, so that
    // feed on its own shows nothing while the board is being worked on.
    boardTimeline: boardTimeline,
    // The same markdown/code/mermaid renderers the chat transcript uses
    // (`lib/markdown.js`), so a plugin showing a whole document (markdown,
    // source, a diagram fence) does not grow a second implementation of any
    // of the three. `markdown` appends fence-aware markdown (code blocks and
    // ```mermaid fences split out, everything else run through inline
    // markdown) into `el` and kicks off mermaid rendering for any diagram
    // fences it found; `code` returns one already-highlighted block for a
    // file that is source but not markdown.
    render: {
      markdown: function (el, text) {
        el.appendChild(renderMarkdownWithFences(text));
        renderMermaidBlocks(el);
      },
      code: function (lang, text) { return buildCodeBlock(lang, text); }
    }
  };
}

/* One row per plugin in the Set up list, and the row's parts. */
var PLUGIN_ROW_CLASS = "mt-1 flex flex-wrap items-center gap-x-4 gap-y-3 rounded-plate-sm border border-rule bg-surface-2 p-2";
var PLUGIN_NAME_CLASS = "font-sans text-sm font-bold text-fg";
var PLUGIN_GROUP_CLASS = "font-mono text-xs uppercase tracking-label text-fg-muted";
var PLUGIN_DESC_CLASS = "min-w-56 flex-1 font-sans text-sm text-fg-muted";

/* Every addon view's chrome: the panel, the rail tab, and its keyboard wiring.
   Built from name/title/group alone, which is all `/api/webui/plugins` answers
   with, so a deferred addon gets a working tab before its script exists.
   Returns the <section> the addon's `mount` is handed. */
function makeViewShell(id, title, group) {
  var panel = document.createElement("div");
  panel.setAttribute("data-view", "true");
  panel.id = "view-" + id;
  panel.setAttribute("role", "region");
  panel.setAttribute("aria-labelledby", "tab-" + id);
  panel.tabIndex = -1;
  panel.hidden = true;
  var section = document.createElement("section");
  panel.appendChild(section);
  var live = document.createElement("p");
  live.className = "sr-only";
  live.id = "plugin-status-" + id;
  live.setAttribute("role", "status");
  live.setAttribute("aria-live", "polite");
  panel.appendChild(live);
  pluginStatusNodes[id] = live;
  // Joins the page's status-to-toast mirror, so a plugin's message is still
  // seen and not only announced.
  if (_observeStatus) _observeStatus(live);
  document.getElementById("main").appendChild(panel);
  var tab = document.createElement("button");
  tab.type = "button";
  tab.className = RAIL_TAB_CLASS;
  tab.id = "tab-" + id;
  tab.setAttribute("aria-controls", "view-" + id);
  tab.setAttribute("data-view", id);
  tab.textContent = title;
  decorateRailTab(tab);
  /* Each rail list names its group (`data-rail-group` in index.html); a
     group no list names lands in Set up, the rail's catch-all. */
  const item = document.createElement("li"),
    list = document.querySelector(`#rail ul[data-rail-group="${group}"]`) ?? document.querySelector('#rail ul[data-rail-group="Set up"]');

  item.append(tab);
  list.append(item);
  _VIEWS.push(id);
  _wireTab(tab, _VIEWS.length - 1);
  return section;
}

/* A plugin's mount (or refresh) is third-party code running inside the page's
   tab switch: a throw that rides up through the view loader breaks the switch
   itself and the page looks dead. Contain it to the plugin's own panel — the
   tab stays, the panel names the plugin and the exception, Retry re-runs the
   loader — and let the rest of the page carry on. */
function runPluginHook(section, label, retryFn, fn) {
  try {
    return fn();
  } catch (e) {
    section.textContent = "";
    var msg = e && e.message ? e.message : String(e);
    showLoadError(section, "The " + label + " plugin failed: " + msg, retryFn);
    return null;
  }
}

/* Addons whose tab exists but whose script has not been fetched yet, keyed by
   view id. `spec` is filled in when that script runs `clanker.registerView`. */
var pluginShells = {};

/* Per-view mount state, keyed by view id: whether `mount` has run, and the
   `refresh` call that a later visit should reach. Held out here rather than in
   a closure so `pluginViewShown` can find it. */
var pluginMounts = {};

/* One view's mount bookkeeping. `getSpec` is a function rather than the spec
   because a deferred addon's spec does not exist yet when its shell is built,
   and because a mount may replace its own `refresh` (health and office both
   assign `this.refresh` from inside `mount`) — so it has to be read at call
   time, not captured. */
function trackMount(id, label, section, getSpec) {
  var st = pluginMounts[id];
  if (st && st.section === section) return st;
  st = { mounted: false, section: section };
  st.retry = function () {
    st.mounted = false;
    return _viewLoaders[id]();
  };
  st.refresh = function () {
    var spec = getSpec();
    if (!spec || typeof spec.refresh !== "function") return null;
    return runPluginHook(section, label, st.retry, function () {
      return spec.refresh.call(spec, section, pluginApi(spec));
    });
  };
  st.mount = function () {
    var spec = getSpec();
    st.mounted = true;
    section.textContent = "";
    return runPluginHook(section, label, st.retry, function () {
      return spec.mount.call(spec, section, pluginApi(spec));
    });
  };
  pluginMounts[id] = st;
  return st;
}

/* The host loads a view once: `viewLoaded[name]` in app.js is set on the first
   successful load and never cleared, so a view loader is not called again and
   `refresh` — documented in PRD 0012 as part of the registration API, and the
   hook mesh relies on for re-entry — was reachable only from the error panel's
   Retry. `showView` calls this whenever it switches to a view it has already
   loaded. It is deliberately a no-op until `mount` has run, so the first open
   still belongs to the loader and a plugin never sees `refresh` before
   `mount`. */
export function pluginViewShown(id) {
  var st = pluginMounts[id];
  if (!st || !st.mounted) return null;
  return st.refresh();
}

/* An enabled, non-eager addon: build its chrome now, fetch its code on first
   open. A script that fails to arrive leaves the tab in place showing the
   failure with a Retry, rather than an empty panel that looks like the addon
   has nothing to say. */
function registerDeferredView(meta) {
  if (pluginShells[meta.name] || _VIEWS.indexOf(meta.name) !== -1) return;
  var section = makeViewShell(meta.name, meta.title || meta.name, meta.group || "Watch");
  var shell = { section: section, spec: null };
  pluginShells[meta.name] = shell;
  var st = trackMount(meta.name, meta.title || meta.name, section, function () { return shell.spec; });
  _viewLoaders[meta.name] = function () {
    if (meta.has_css) loadPluginCss(meta.name);
    return loadPluginScript(meta.name).then(function (ok) {
      if (!ok || !shell.spec) {
        st.mounted = false;
        section.textContent = "";
        showLoadError(section, "Could not load the " + (meta.title || meta.name) + " plugin.", function () {
          pluginScripts[meta.name] = null;
          return _viewLoaders[meta.name]();
        });
        return null;
      }
      if (!st.mounted) return st.mount();
      return st.refresh();
    });
  };
}

/* Inject one addon's app.js, once, and resolve when it has run (or failed).
   Kept in a map so the deferred view loader and an eager boot cannot race two
   <script> tags for the same addon. */
var pluginScripts = {};

function loadPluginScript(name) {
  if (pluginScripts[name]) return pluginScripts[name];
  pluginScripts[name] = new Promise(function (resolve) {
    var existing = document.querySelector('script[data-plugin="' + name + '"]');
    if (existing) { resolve(true); return; }
    var s = document.createElement("script");
    s.src = new URL("../plugins/" + encodeURIComponent(name) + "/app.js", import.meta.url).href;
    s.setAttribute("data-plugin", name);
    s.onload = function () { resolve(true); };
    s.onerror = function () {
      // Take the dead tag out of the head, or every Retry is a no-op: the
      // error panel's retry resets the promise cache and calls back in here,
      // and the `existing` check above would find this failed <script> and
      // resolve true without ever refetching the file.
      s.remove();
      hostStatus("Plugin " + name + " failed to load.");
      resolve(false);
    };
    document.head.appendChild(s);
  });
  return pluginScripts[name];
}

function loadPluginCss(name) {
  if (document.querySelector('link[data-plugin="' + name + '"]')) return;
  var link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = new URL("../plugins/" + encodeURIComponent(name) + "/app.css", import.meta.url).href;
  link.setAttribute("data-plugin", name);
  document.head.appendChild(link);
}

/* An enabled addon's tab, panel and nav entry come from its manifest
   (`/api/webui/plugins` already answers name/title/group/has_css), so the page
   can offer the addon without downloading a byte of it. Its app.js and app.css
   are fetched the first time its tab is opened, the same deferral the
   first-party feature views get from `load<View>Module` in app.js.

   `eager: true` in plugin.json opts out, for an addon that does work outside
   its own view — the music dock is the shipped case. Everything else stays off
   the wire until asked for: the nine shipped addons are ~200 KB of script and
   CSS and ~18 requests that every visit, chat-only ones included, used to pay
   for on load.

   `module: true` is the third shape: not a view at all. Its app.js is an ES
   module a core view imports on demand (arena3d), so the page must not build a
   tab for it or fetch it as a classic script — the manifest row only carries
   the name so the System → Web UI plugins checkbox gates its assets. */
export function loadPluginAssets(list) {
  var pending = [];
  list.forEach(function (p) {
    if (!p.enabled) return;
    if (p.module) return;
    if (p.eager) {
      if (p.has_css) loadPluginCss(p.name);
      pending.push(loadPluginScript(p.name));
      return;
    }
    registerDeferredView(p);
  });
  // The kit first: a plugin reaches for api.kit as soon as its script runs, so
  // the import has to be resolved before the first of them is injected.
  return loadKit().then(function () { return Promise.all(pending); });
}

export function loadWebuiPlugins() {
  return fetch("/api/webui/plugins")
    .then(_readJson)
    .then(function (d) {
      // The webui_addon guest owns the registry now; its list answer is
      // `addons` (with has_css), passed through verbatim by the HTTP route.
      renderWebuiPlugins(d.addons || []);
      return loadPluginAssets(d.addons || []);
    })
    .catch(function (err) {
      var msg = "Could not load plugins: " + err.message;
      hostStatus(msg);
      showLoadError(_el.webuiPlugins, msg, loadWebuiPlugins);
    });
}

export function renderWebuiPlugins(list) {
  _el.webuiPlugins.textContent = "";
  if (!list.length) {
    var none = document.createElement("p");
    none.className = "run-empty";
    none.textContent = "No plugins installed. A plugin is a directory under ui/plugins/; see its README.";
    _el.webuiPlugins.appendChild(none);
    return;
  }
  list.forEach(function (p) {
    var row = document.createElement("div");
    row.className = PLUGIN_ROW_CLASS;
    var box = document.createElement("input");
    box.type = "checkbox";
    box.id = "plugin-" + p.name;
    box.checked = !!p.enabled;
    box.addEventListener("change", function () {
      box.disabled = true;
      fetch("/api/webui/plugins", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: p.name, enabled: box.checked })
      })
        .then(_readJson)
        .then(function (d) {
          var nowOn = box.checked;
          renderWebuiPlugins(d.addons || []);
          if (nowOn) {
            return loadPluginAssets(d.addons || []).then(function () {
              hostStatus((p.title || p.name) + " enabled.");
            });
          }
          hostStatus((p.title || p.name) + " disabled. Reload the page to remove it.");
          var note = document.createElement("p");
          note.className = "run-empty";
          note.appendChild(document.createTextNode((p.title || p.name) + " is off. Reload the page to take it off this screen. "));
          var reload = document.createElement("button");
          reload.type = "button";
          reload.className = "secondary";
          reload.textContent = "Reload page";
          reload.addEventListener("click", function () { window.location.reload(); });
          note.appendChild(reload);
          _el.webuiPlugins.appendChild(note);
        })
        .catch(function (err) {
          box.checked = !box.checked;
          hostStatus("Plugin: " + err.message);
        })
        .then(function () { box.disabled = false; });
    });
    var name = document.createElement("label");
    name.className = PLUGIN_NAME_CLASS;
    name.htmlFor = box.id;
    name.textContent = p.title || p.name;
    var desc = document.createElement("span");
    desc.className = PLUGIN_DESC_CLASS;
    desc.textContent = p.description || "";
    var group = document.createElement("span");
    group.className = PLUGIN_GROUP_CLASS;
    group.textContent = p.group || "";
    row.appendChild(box);
    row.appendChild(name);
    row.appendChild(desc);
    row.appendChild(group);
    _el.webuiPlugins.appendChild(row);
  });
}

/* `boot` is the page-load hook (a persistent dock, a live subscription), and it
   has no panel to show an error in: mount's containment writes into the view's
   own section, but a throwing boot used to disappear into an empty catch and
   the plugin's dock was simply absent with nothing anywhere saying why. The
   loader's status line is the surface that exists at boot time, so the failure
   lands there, named. */
function runPluginBoot(spec) {
  if (typeof spec.boot !== "function") return;
  try {
    spec.boot(pluginApi(spec));
  } catch (e) {
    var msg = e && e.message ? e.message : String(e);
    hostStatus("The " + (spec.title || spec.id) + " plugin failed to start: " + msg);
  }
}

export function bindPlugins(ctx) {
  _VIEWS = ctx.VIEWS;
  _viewLoaders = ctx.viewLoaders;
  _wireTab = ctx.wireTab;
  _showView = ctx.showView;
  _el = ctx.el;
  _readJson = ctx.readJson;
  _fmtBytes = ctx.fmtBytes;
  _fmtInt = ctx.fmtInt;
  _fmtCost = ctx.fmtCost;
  _formatChatTime = ctx.formatChatTime;
  _openSession = ctx.openSession;
  _observeStatus = ctx.observeStatus || null;
  window.clanker = {
    registerView: function (spec) {
      if (!spec || !spec.id || typeof spec.mount !== "function") return;
      // The tab may already be on screen: a deferred addon's shell is built
      // from its manifest and its script only runs once the tab is opened, so
      // this call is the mount arriving, not a second view.
      var shell = pluginShells[spec.id];
      if (shell) {
        shell.spec = spec;
        pluginViews[spec.id] = { spec: spec, section: shell.section };
        runPluginBoot(spec);
        return;
      }
      if (_VIEWS.indexOf(spec.id) !== -1) return;
      var section = makeViewShell(spec.id, spec.title || spec.id, spec.group || "Watch");
      pluginViews[spec.id] = { spec: spec, section: section };
      var st = trackMount(spec.id, spec.title || spec.id, section, function () { return spec; });
      _viewLoaders[spec.id] = function () {
        if (!st.mounted) return st.mount();
        return st.refresh();
      };
      runPluginBoot(spec);
    }
  };
  wireRefresh(_el.webuiPluginsRefresh, loadWebuiPlugins);
}
