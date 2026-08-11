// Fleet / cross-agent view — ES module, no bundler.
// Owns #view-fleet: roster + grouped runs. Works without app.js.
import { clip } from "../core/utils.js";

function readJson(r) {
  return r.json().then(function (d) {
    if (!r.ok) throw new Error((d && d.error) || "HTTP " + r.status);
    return d;
  }, function () {
    if (!r.ok) throw new Error("HTTP " + r.status);
    return {};
  });
}

function byId(id) { return document.getElementById(id); }

var SUB_RE = /\[subagent run:\s*(sub-\d+)\]/g;

function extractSubIds(text) {
  var out = [];
  if (!text) return out;
  var m;
  while ((m = SUB_RE.exec(text)) !== null) out.push(m[1]);
  SUB_RE.lastIndex = 0;
  return out;
}

function groupRuns(runs) {
  var byParent = Object.create(null);
  var byIdMap = Object.create(null);
  runs.forEach(function (r) { byIdMap[r.run_id] = r; });
  var roots = [];
  runs.forEach(function (r) {
    var pid = r.parent_run_id || "";
    if (pid && byIdMap[pid]) {
      if (!byParent[pid]) byParent[pid] = [];
      byParent[pid].push(r);
    } else {
      roots.push(r);
    }
  });
  var childIds = {};
  Object.keys(byParent).forEach(function (k) {
    byParent[k].forEach(function (c) { childIds[c.run_id] = true; });
  });
  roots = runs.filter(function (r) { return !childIds[r.run_id]; });
  return { roots: roots, childrenOf: byParent, byId: byIdMap };
}

function fmtRunMeta(r) {
  var kind = r.run_id && r.run_id.indexOf("sub-") === 0 ? "sub" : "run";
  var dur = typeof r.duration_ms === "number" ? r.duration_ms + "ms" : "";
  var prov = r.provider || "";
  return [kind, prov, dur].filter(Boolean).join(" \u00b7 ");
}

function el(tag, cls, text) {
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

function skeleton(container, count) {
  container.textContent = "";
  for (var i = 0; i < count; i++) {
    var s = el("div", "fleet-skeleton");
    if (i === count - 1) s.className += " fleet-skeleton--sm";
    container.appendChild(s);
  }
}

function renderError(container, msg, retryFn) {
  container.textContent = "";
  var p = el("p", "run-empty", msg);
  container.appendChild(p);
  if (typeof retryFn === "function") {
    var btn = el("button", "secondary", "Retry");
    btn.type = "button";
    btn.addEventListener("click", retryFn);
    container.appendChild(btn);
  }
}

function renderRoster(container, status) {
  container.textContent = "";
  if (!status || !status.instance) {
    container.appendChild(el("p", "run-empty", "No status yet."));
    return;
  }
  var inst = status.instance;
  var head = el("p", "meta");
  head.textContent = inst.name + " (" + inst.id.slice(0, 8) + ")";
  container.appendChild(head);
  var peers = status.peers || [];
  if (!peers.length) {
    container.appendChild(el("p", "run-empty", "No peers configured."));
    return;
  }
  var ul = el("ul", "fleet-roster-list");
  peers.forEach(function (p) {
    var li = el("li", "meta");
    li.textContent = p.name + " \u2014 " + p.url;
    li.title = p.url;
    ul.appendChild(li);
  });
  container.appendChild(ul);
}

function renderRuns(container, detailNode, runs) {
  container.textContent = "";
  if (!runs.length) {
    container.appendChild(el("p", "run-empty", "No runs recorded yet."));
    return;
  }
  var grouped = groupRuns(runs);

  function openRun(id) {
    if (typeof window.openRun === "function") {
      try { window.openRun(id); return; } catch (_) {}
    }
    var hashView = document.getElementById("tab-runs");
    if (hashView) {
      detailNode.textContent = "";
      detailNode.appendChild(el("p", "meta", "Loading " + id + "\u2026"));
      detailNode.hidden = false;
      fetch("/api/runs/" + encodeURIComponent(id)).then(readJson).then(function (g) {
        var body = g.text ? JSON.parse(g.text) : g;
        renderSimpleGraph(detailNode, body);
      }).catch(function (e) {
        detailNode.textContent = "";
        detailNode.appendChild(el("p", "run-empty", "Could not load " + id + ": " + e.message));
      });
      return;
    }
    fetch("/api/runs/" + encodeURIComponent(id)).then(readJson).then(function (g) {
      detailNode.textContent = "";
      var body = g.text ? JSON.parse(g.text) : g;
      renderSimpleGraph(detailNode, body);
      detailNode.hidden = false;
    }).catch(function () {});
  }

  function fleetCardKeyHandler(e, id) {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); openRun(id); }
  }

  grouped.roots.forEach(function (root) {
    var hasKids = !!(grouped.childrenOf[root.run_id] && grouped.childrenOf[root.run_id].length);
    var card = el("div", "tool-row fleet-card " + (hasKids ? "fleet-card--accent" : "fleet-card--plain"));
    card.tabIndex = 0;
    card.setAttribute("role", "button");
    card.setAttribute("aria-label", "Open run " + root.run_id);
    card.addEventListener("keydown", function (e) { fleetCardKeyHandler(e, root.run_id); });
    card.addEventListener("click", function (e) {
      if (e.target.closest && e.target.closest("button")) return;
      openRun(root.run_id);
    });
    var left = el("div", "fleet-card__main");
    var title = el("div", "tool-name", clip(root.task || root.run_id, 120));
    title.title = root.task || root.run_id;
    var meta = el("div", "meta", root.run_id + " \u00b7 " + fmtRunMeta(root));
    left.appendChild(title);
    left.appendChild(meta);
    var actions = el("div", "toolbar-actions");
    var btn = el("button", "secondary", "Open");
    btn.type = "button";
    btn.addEventListener("click", function () { openRun(root.run_id); });
    actions.appendChild(btn);
    card._open = openRun;
    card.appendChild(left);
    card.appendChild(actions);
    container.appendChild(card);

    var children = grouped.childrenOf[root.run_id] || [];
    if (children.length) {
      var sub = el("div", "fleet-children");
      children.forEach(function (child) {
        var row = el("div", "tool-row fleet-card fleet-child");
        row.tabIndex = 0;
        row.setAttribute("role", "button");
        row.setAttribute("aria-label", "Open run " + child.run_id);
        row.addEventListener("keydown", function (e) { fleetCardKeyHandler(e, child.run_id); });
        row.addEventListener("click", function (e) {
          if (e.target.closest && e.target.closest("button")) return;
          openRun(child.run_id);
        });
        var l2 = el("div", "fleet-child__main");
        l2.appendChild(el("div", "tool-name", child.run_id));
        l2.appendChild(el("div", "meta", clip(child.task || "", 100) + (child.task ? " \u00b7 " : "") + fmtRunMeta(child)));
        var a2 = el("div", "toolbar-actions");
        var b2 = el("button", "secondary", "Open");
        b2.type = "button";
        b2.addEventListener("click", function () { openRun(child.run_id); });
        a2.appendChild(b2);
        row.appendChild(l2);
        row.appendChild(a2);
        sub.appendChild(row);
      });
      container.appendChild(sub);
    }

    if (!children.length && root.run_id.indexOf("sub-") !== 0) {
      fetch("/api/runs/" + encodeURIComponent(root.run_id)).then(readJson).then(function (g) {
        var body = g.text ? JSON.parse(g.text) : g;
        var ids = [];
        (body.nodes || []).forEach(function (n) {
          extractSubIds(n.output || "").forEach(function (sid) { if (ids.indexOf(sid) === -1) ids.push(sid); });
          extractSubIds(n.detail || "").forEach(function (sid) { if (ids.indexOf(sid) === -1) ids.push(sid); });
        });
        if (!ids.length) return;
        var extra = ids.filter(function (sid) { return !grouped.byId[sid]; });
        if (!extra.length) return;
        var note = el("div", "meta fleet-note");
        note.textContent = "Sub-runs referenced in output: " + extra.join(", ");
        container.appendChild(note);
        extra.forEach(function (sid) {
          var row2 = el("div", "tool-row fleet-card fleet-extra-row");
          row2.tabIndex = 0;
          row2.setAttribute("role", "button");
          row2.setAttribute("aria-label", "Open run " + sid);
          row2.addEventListener("keydown", function (e) { fleetCardKeyHandler(e, sid); });
          row2.addEventListener("click", function (e) {
            if (e.target.closest && e.target.closest("button")) return;
            openRun(sid);
          });
          row2.appendChild(el("div", "tool-name", sid));
          var a = el("div", "toolbar-actions");
          var b = el("button", "secondary", "Open");
          b.type = "button";
          b.addEventListener("click", function () { openRun(sid); });
          a.appendChild(b);
          row2.appendChild(a);
          container.appendChild(row2);
        });
      }).catch(function () {});
    }
  });
}

function renderSimpleGraph(container, g) {
  container.textContent = "";
  var head = el("p", "run-head");
  head.textContent = (g.run_id || "") + " \u00b7 " + (g.provider || "?") + " \u00b7 " + (g.duration_ms || 0) + "ms\n" + (g.task || "");
  container.appendChild(head);
  var nodes = g.nodes || [];
  if (!nodes.length) {
    container.appendChild(el("p", "run-empty", "No nodes recorded."));
    return;
  }
  var stages = [];
  var final = null;
  nodes.forEach(function (n) {
    if (n.kind === "llm") stages.push({ llm: n, tools: [] });
    else if (n.kind === "tool" && stages.length) stages[stages.length - 1].tools.push(n);
    else if (n.kind === "final") final = n;
  });
  stages.forEach(function (st, idx) {
    var sec = el("div", "fleet-stage");
    var label = el("div", "tool-name", "iter " + (st.llm.iteration || idx + 1) + " \u00b7 llm " + (st.llm.label || ""));
    var meta = el("div", "meta", (st.llm.prompt_tokens || 0) + "/" + (st.llm.completion_tokens || 0) + " tok \u00b7 " + (st.llm.duration_ms || 0) + "ms");
    sec.appendChild(label);
    sec.appendChild(meta);
    if (st.tools.length) {
      var ul = el("ul", "fleet-stage__tools");
      st.tools.forEach(function (t) {
        var li = el("li", "meta", t.label + " \u00b7 " + (t.result_bytes || 0) + " B \u00b7 " + (t.duration_ms || 0) + "ms" + (t.ok === false ? " \u00b7 FAIL" : ""));
        if (t.ok === false) li.className += " fleet-fail";
        ul.appendChild(li);
      });
      sec.appendChild(ul);
    }
    container.appendChild(sec);
  });
  if (final) {
    var f = el("p", "meta", "final \u00b7 " + (final.result_bytes || 0) + " B" + (final.detail ? " \u00b7 " + final.detail : ""));
    container.appendChild(f);
  }
  var close = el("button", "secondary", "Close");
  close.type = "button";
  close.addEventListener("click", function () { container.hidden = true; container.textContent = ""; });
  container.appendChild(close);
}

var _refreshAll = null;

export function refreshFleet() {
  if (_refreshAll) return Promise.resolve(_refreshAll());
  return Promise.resolve(null);
}

export function initFleet() {
  var view = byId("view-fleet");
  if (!view) return;
  var roster = byId("fleet-roster");
  var runsEl = byId("fleet-runs");
  var detail = byId("fleet-detail");
  var statusEl = byId("fleet-status");
  var refresh = byId("fleet-refresh");
  if (!roster || !runsEl) return;

  function doRefresh() {
    if (refresh) refresh.disabled = true;
    if (statusEl) statusEl.textContent = "Loading\u2026";
    skeleton(roster, 2);
    skeleton(runsEl, 3);
    var statusP = fetch("/api/status").then(readJson).catch(function (e) { return { __err: e }; });
    var runsP = fetch("/api/runs").then(readJson).then(function (d) {
      var txt = d.text || "";
      if (txt) { try { return JSON.parse(txt); } catch (_) { return []; } }
      return Array.isArray(d) ? d : (d.runs || []);
    }).catch(function (e) { return { __err: e }; });
    return Promise.all([statusP, runsP]).then(function (vals) {
      var s = vals[0];
      var r = vals[1];
      if (s && s.__err) renderError(roster, "Could not load roster: " + s.__err.message, doRefresh);
      else renderRoster(roster, s);
      if (r && r.__err) renderError(runsEl, "Could not load runs: " + r.__err.message, doRefresh);
      else renderRuns(runsEl, detail, r || []);
      if (statusEl) {
        if (r && r.__err) statusEl.textContent = r.__err.message;
        else if (s && s.__err) statusEl.textContent = s.__err.message;
        else statusEl.textContent = (r || []).length ? "" : "No runs yet.";
      }
    }).catch(function (e) {
      if (statusEl) statusEl.textContent = e.message || "Failed to load.";
    }).then(function () { if (refresh) refresh.disabled = false; });
  }
  _refreshAll = doRefresh;
  if (refresh && !refresh._fleetBound) {
    refresh._fleetBound = true;
    refresh.addEventListener("click", doRefresh);
  }
  doRefresh();
  window.clankerFleet = window.clankerFleet || {};
  window.clankerFleet.refresh = function () { return doRefresh(); };
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initFleet);
} else {
  initFleet();
}
