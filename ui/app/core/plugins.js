// Vanilla, no bundler. Web UI plugin host — view registration + asset loading.
import { T, state, add, effect, showLoadError, upgradePfButton, uiConfirm, uiPrompt, toast } from "./ui.js";
import { renderMarkdownWithFences, buildCodeBlock, renderMermaidBlocks } from "../lib/markdown.js";
import { boardTimeline } from "../lib/board.js";
import { onLive } from "./stream.js";
import { icon } from "./icons.js";
import { searchFoldFind } from "./utils.js";

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

function fmt() { return { bytes: _fmtBytes, int: _fmtInt, cost: _fmtCost, time: _formatChatTime }; }

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
    status: function (message) { _el.webuiPluginsStatus.textContent = message; },
    fmt: fmt(),
    // Kept under the old name so plugins written against the VanJS-era API
    // keep working: same tags/state/add semantics, now signals-backed.
    van: { tags: T, state: state, add: add, derive: effect },
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

export function loadPluginAssets(list) {
  var pending = [];
  list.forEach(function (p) {
    if (!p.enabled) return;
    if (p.has_css && !document.querySelector('link[data-plugin="' + p.name + '"]')) {
      var link = document.createElement("link");
      link.rel = "stylesheet";
      link.href = new URL("../plugins/" + encodeURIComponent(p.name) + "/app.css", import.meta.url).href;
      link.setAttribute("data-plugin", p.name);
      document.head.appendChild(link);
    }
    if (document.querySelector('script[data-plugin="' + p.name + '"]')) return;
    pending.push(new Promise(function (resolve) {
      var s = document.createElement("script");
      s.src = new URL("../plugins/" + encodeURIComponent(p.name) + "/app.js", import.meta.url).href;
      s.setAttribute("data-plugin", p.name);
      s.onload = function () { resolve(true); };
      s.onerror = function () {
        _el.webuiPluginsStatus.textContent = "Plugin " + p.name + " failed to load.";
        resolve(false);
      };
      document.head.appendChild(s);
    }));
  });
  return Promise.all(pending);
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
      _el.webuiPluginsStatus.textContent = msg;
      showLoadError(_el.webuiPlugins, msg, loadWebuiPlugins);
    });
}

export function renderWebuiPlugins(list) {
  _el.webuiPlugins.textContent = "";
  if (!list.length) {
    var none = document.createElement("p");
    none.className = "run-empty";
    none.textContent = "No plugins installed. A plugin is a directory under ui/plugins/ — see its README.";
    _el.webuiPlugins.appendChild(none);
    return;
  }
  list.forEach(function (p) {
    var row = document.createElement("div");
    row.className = "webui-plugin";
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
              _el.webuiPluginsStatus.textContent = (p.title || p.name) + " enabled.";
            });
          }
          _el.webuiPluginsStatus.textContent = (p.title || p.name) + " disabled. Reload the page to remove it.";
          var note = document.createElement("p");
          note.className = "run-empty";
          note.appendChild(document.createTextNode((p.title || p.name) + " is off. Reload the page to take it off this screen. "));
          var reload = document.createElement("button");
          reload.type = "button";
          reload.className = "secondary";
          reload.textContent = "Reload page";
          upgradePfButton(reload);
          reload.addEventListener("click", function () { window.location.reload(); });
          note.appendChild(reload);
          _el.webuiPlugins.appendChild(note);
        })
        .catch(function (err) {
          box.checked = !box.checked;
          _el.webuiPluginsStatus.textContent = "Plugin: " + err.message;
        })
        .then(function () { box.disabled = false; });
    });
    var name = document.createElement("label");
    name.className = "webui-plugin-name";
    name.htmlFor = box.id;
    name.textContent = p.title || p.name;
    var desc = document.createElement("span");
    desc.className = "webui-plugin-desc";
    desc.textContent = p.description || "";
    var group = document.createElement("span");
    group.className = "webui-plugin-group";
    group.textContent = p.group || "";
    row.appendChild(box);
    row.appendChild(name);
    row.appendChild(desc);
    row.appendChild(group);
    _el.webuiPlugins.appendChild(row);
  });
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
  window.clanker = {
    registerView: function (spec) {
      if (!spec || !spec.id || typeof spec.mount !== "function") return;
      if (_VIEWS.indexOf(spec.id) !== -1) return;
      var group = spec.group || "Watch";
      var panel = document.createElement("div");
      panel.className = "view";
      panel.id = "view-" + spec.id;
      panel.setAttribute("role", "tabpanel");
      panel.setAttribute("aria-labelledby", "tab-" + spec.id);
      panel.tabIndex = -1;
      panel.hidden = true;
      var section = document.createElement("section");
      panel.appendChild(section);
      document.getElementById("main").appendChild(panel);
      var tab = document.createElement("button");
      tab.type = "button";
      tab.className = "rail-tab";
      tab.setAttribute("role", "tab");
      tab.id = "tab-" + spec.id;
      tab.setAttribute("aria-controls", "view-" + spec.id);
      tab.setAttribute("aria-selected", "false");
      tab.tabIndex = -1;
      tab.setAttribute("data-view", spec.id);
      tab.textContent = spec.title || spec.id;
      var rail = document.getElementById("rail");
      var headings = rail ? rail.querySelectorAll(".rail-group") : [];
      var placed = false;
      for (var i = 0; i < headings.length; i++) {
        if ((headings[i].textContent || "").trim() !== group) continue;
        var host = headings[i].closest("details, section, nav") || headings[i].parentNode;
        var list = host.querySelector(".pf-v6-c-nav__list");
        if (list) {
          var item = document.createElement("li");
          item.className = "pf-v6-c-nav__item";
          item.appendChild(tab);
          list.appendChild(item);
        } else {
          host.appendChild(tab);
        }
        placed = true;
        break;
      }
      if (!placed) {
        var fallback = document.querySelector(".rail-nav");
        if (fallback) fallback.appendChild(tab);
      }
      var tablist = document.querySelector(".rail-places[role='tablist']");
      if (tablist && tab.id) {
        var owns = (tablist.getAttribute("aria-owns") || "").split(/\s+/).filter(Boolean);
        if (owns.indexOf(tab.id) === -1) {
          owns.push(tab.id);
          tablist.setAttribute("aria-owns", owns.join(" "));
        }
      }
      _VIEWS.push(spec.id);
      pluginViews[spec.id] = { spec: spec, section: section };
      var mounted = false;
      _viewLoaders[spec.id] = function () {
        if (!mounted) {
          mounted = true;
          return spec.mount.call(spec, section, pluginApi(spec));
        }
        if (typeof spec.refresh === "function") return spec.refresh.call(spec, section, pluginApi(spec));
        return null;
      };
      _wireTab(tab, _VIEWS.length - 1);
      if (typeof spec.boot === "function") {
        try { spec.boot(pluginApi(spec)); } catch (e) {}
      }
    }
  };
  if (_el.webuiPluginsRefresh && !_el.webuiPluginsRefresh._bound) {
    _el.webuiPluginsRefresh._bound = true;
    _el.webuiPluginsRefresh.addEventListener("click", function () { loadWebuiPlugins(); });
  }
}
