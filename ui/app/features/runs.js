// Runs view — the recorded-run picker, its execution graph, the node detail
// panel and the A/B run diff. ES module, no bundler.
//
// This used to sit inline in app.js, ~64 KB raw / ~19 KB gz that every
// chat-only visit downloaded and never executed. It is now lazy like every
// other feature view (`loadRunsModule` in app.js); the graph *layout* it
// delegates to `lib/graph.js` was already a second lazy hop and still is.
//
// app.js owns the page chrome, so the DOM handle map, the view switcher, the
// per-view loaded flags and the hash parser arrive through `initRuns` rather
// than being re-derived here. Everything else is imported directly, which is
// what takes `lib/runs-list.js` off the eager path with this module.
import { fmtInt, fmtMs, escapeHtml, readJson } from "../core/utils.js";
import { skeletonRows, upgradePfButton, showLoadError } from "../core/ui.js";
import { icon } from "../core/icons.js";
import { loadD3, copyText, scrollTo } from "../core/vendor.js";
import { runLabel } from "../core/labels.js";
import { highlightInto } from "../lib/markdown.js";
import { runRows as runRowsMod, groupRunsByDay as groupRunsByDayMod, matchesRunQuery, runFailed } from "../lib/runs-list.js";

/* Set by app.js on first load. `el` is its element map, `showView` its view
   switcher, `viewLoaded` its per-view "has been opened" flags and
   `parseRunsHash` its deep-link parser. */
var el = {};
var showView = function () {};
var viewLoaded = {};
var parseRunsHash = function () { return null; };
export function initRuns(ctx) {
  el = ctx.el;
  showView = ctx.showView;
  viewLoaded = ctx.viewLoaded;
  parseRunsHash = ctx.parseRunsHash;

  /* The listbox's rows all carry tabindex=-1, so Tab lands on the container
     and stops there — no option is reachable. The adjacent native <select>
     covers the flow, but a listbox whose options only answer to the mouse is
     dead weight for a keyboard user, so arrows/Home/End move the selection
     here instead. Each move is the same act as clicking a row (selection
     through the select, graph load, row highlight), and loadRun's "Loading
     run …" status write announces it. */
  if (el.runList) {
    el.runList.addEventListener("keydown", function (e) {
      var rows = el.runList.querySelectorAll(".run-row");
      if (!rows.length) return;
      var idx = 0;
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].getAttribute("aria-selected") === "true") { idx = i; break; }
      }
      if (e.key === "Home") {
        idx = 0;
      } else if (e.key === "End") {
        idx = rows.length - 1;
      } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        idx = (idx + (e.key === "ArrowDown" ? 1 : -1) + rows.length) % rows.length;
      } else {
        return;
      }
      e.preventDefault();
      var row = rows[idx];
      selectRunFromList(row.dataset.runId);
      row.focus();
    });
  }
}

// ---- runs: pick a recorded run, draw its execution graph ----------------

var allRunsHolder = { list: [] };
var allRuns = allRunsHolder.list;
/* Set when something asks for one particular run before the Runs view has
   loaded its list. */
var pendingRunId = null;

/* Rebuilds the <select>'s actual option list from allRuns filtered by
   substring match on task text or run id — kept as a real native <select>
   (free keyboard nav, native mobile picker) rather than a custom dropdown;
   hiding <option>s with CSS isn't reliably respected by every browser's
   native combobox rendering, but replacing the option list outright always
   works. */
function renderRunOptions(filterText) {
  var q = (filterText || "").trim().toLowerCase();
  var matches = allRuns.filter(function (r) { return matchesRunQuery(r, q); });
  var previous = el.runSelect.value;
  el.runSelect.textContent = "";
  matches.forEach(function (r) {
    var opt = document.createElement("option");
    opt.value = r.run_id;
    opt.textContent = runLabel(r);
    el.runSelect.appendChild(opt);
  });
  renderRunList(matches);
  if (!matches.length) {
    el.runSelect.disabled = true;
    el.runGraph.textContent = "";
    // The open node detail belongs to a run that is no longer listed or
    // drawn; leaving it up would attribute one run's output to whatever is
    // selected next.
    closeNodeDetail();
    var none = document.createElement("p");
    none.className = "run-empty";
    if (q) {
      none.appendChild(document.createTextNode("No recorded runs match “" + filterText.trim() + "”. "));
      var clear = document.createElement("button");
      clear.type = "button";
      clear.className = "secondary";
      clear.textContent = "Clear filter";
      clear.addEventListener("click", function () {
        el.runFilter.value = "";
        el.runFilter.dispatchEvent(new Event("input", { bubbles: true }));
        el.runFilter.focus();
      });
      none.appendChild(clear);
    } else {
      none.appendChild(document.createTextNode("No runs recorded yet. Start a task in Chat and it appears here. "));
      var go = document.createElement("button");
      go.type = "button";
      go.className = "primary";
      go.textContent = "Open Chat";
      go.addEventListener("click", function () {
        var tab = document.getElementById("tab-chat");
        if (tab) tab.click();
        else showView("chat", true);
      });
      none.appendChild(go);
    }
    el.runGraph.appendChild(none);
    announceRunMatches(q, 0);
    return null;
  }
  el.runSelect.disabled = false;
  var wanted = matches.some(function (r) { return r.run_id === previous; }) ? previous : matches[0].run_id;
  el.runSelect.value = wanted;
  announceRunMatches(q, matches.length);
  return wanted;
}

/* The browsable half of the picker. The select can only ever show the one run
   it has selected, which is why a listing that had gone stale looked exactly
   like a current one — nothing on screen carried a date. Each row here is
   dated, grouped under the day it ran, and says what the run did. */
function renderRunList(matches) {
  if (!el.runList) return;
  var rows = runRowsMod(matches, { now: Date.now() });
  var selected = el.runSelect.value;
  el.runList.textContent = "";
  if (el.runListCount) {
    el.runListCount.textContent = rows.length
      ? rows.length + (rows.length === 1 ? " run" : " runs")
      : "";
  }
  if (!rows.length) {
    var empty = document.createElement("p");
    empty.className = "run-empty";
    empty.textContent = "No recorded runs to show.";
    el.runList.appendChild(empty);
    return;
  }
  groupRunsByDayMod(rows, Date.now()).forEach(function (group) {
    var head = document.createElement("div");
    head.className = "run-row-day";
    head.textContent = group.day;
    el.runList.appendChild(head);
    group.rows.forEach(function (row) {
      el.runList.appendChild(buildRunRow(row, row.id === selected));
    });
  });
}

/* One row. `role=option` under the list's `role=listbox`, so the whole thing
   is one control to a screen reader rather than a pile of buttons. */
function buildRunRow(row, isSelected) {
  var item = document.createElement("div");
  item.className = "run-row" + (isSelected ? " is-selected" : "") + (row.nested ? " is-nested" : "") + (row.failed ? " is-failed" : "");
  item.setAttribute("role", "option");
  item.setAttribute("aria-selected", isSelected ? "true" : "false");
  item.tabIndex = -1;
  item.dataset.runId = row.id;

  var top = document.createElement("div");
  top.className = "run-row-top";
  var task = document.createElement("span");
  task.className = "run-row-task";
  task.textContent = row.task;
  task.title = row.task;
  top.appendChild(task);
  var when = document.createElement("span");
  when.className = "run-row-when";
  when.textContent = row.when;
  top.appendChild(when);
  item.appendChild(top);

  var meta = document.createElement("div");
  meta.className = "run-row-meta";
  // The id is what `clanker graph <id>` and every record refers to, so it
  // stays visible rather than living only in a tooltip.
  meta.appendChild(runRowChip(row.id, "run-row-id"));
  if (row.nested) meta.appendChild(runRowChip("sub-agent of " + row.parentId, "run-row-nested"));
  if (row.provider) meta.appendChild(runRowChip(row.provider, "run-row-provider"));
  if (row.nodes) meta.appendChild(runRowChip(fmtInt(row.nodes) + (row.nodes === 1 ? " step" : " steps"), ""));
  if (row.durationMs) meta.appendChild(runRowChip(fmtMs(row.durationMs), ""));
  if (row.tokens) meta.appendChild(runRowChip(fmtInt(row.tokens) + " tok", ""));
  if (row.failed) meta.appendChild(runRowChip("⚠ failed check", "run-row-failed"));
  item.appendChild(meta);

  item.addEventListener("click", function () { selectRunFromList(row.id); });
  item.addEventListener("keydown", function (e) {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      selectRunFromList(row.id);
    }
  });
  return item;
}

function runRowChip(text, cls) {
  var span = document.createElement("span");
  span.className = "run-row-chip" + (cls ? " " + cls : "");
  span.textContent = text;
  return span;
}

/* Clicking a row is the same act as choosing from the select, so it goes
   through the select: one selection, one source of truth, and the `change`
   handler that loads the graph keeps working untouched. */
function selectRunFromList(id) {
  if (el.runSelect.value === id) {
    loadRun(id);
  } else {
    el.runSelect.value = id;
    el.runSelect.dispatchEvent(new Event("change", { bubbles: true }));
  }
  markSelectedRunRow(id);
}

function markSelectedRunRow(id) {
  if (!el.runList) return;
  var rows = el.runList.querySelectorAll(".run-row");
  for (var i = 0; i < rows.length; i++) {
    var on = rows[i].dataset.runId === id;
    rows[i].classList.toggle("is-selected", on);
    rows[i].setAttribute("aria-selected", on ? "true" : "false");
  }
}

/* The filter's whole result — how many runs matched, which one is now shown —
   is conveyed by the option list and the graph redrawing, both silent. Says
   it out loud for anyone who can't see either. Left empty while unfiltered,
   so simply loading the page announces nothing. */
function announceRunMatches(query, count) {
  if (!query) {
    el.runStatus.textContent = "";
    return;
  }
  el.runStatus.textContent = count === 0
    ? "No runs match " + query + "."
    : count + (count === 1 ? " run matches " : " runs match ") + query + ". Showing the first.";
}

function loadRuns() {
  el.runGraph.setAttribute("aria-busy", "true");
  el.runStatus.textContent = "Loading runs…";
  if (!el.runGraph.childNodes.length) skeletonRows(el.runGraph, 3);
  return fetch("/api/runs")
    .then(readJson)
    .then(function (runs) {
      el.runGraph.removeAttribute("aria-busy");
      allRunsHolder.list.length = 0; Array.prototype.push.apply(allRunsHolder.list, runs); allRuns = allRunsHolder.list;
      // A run asked for by name wins over the filter's first match, which was
      // otherwise a race between two graph fetches on first open.
      if (pendingRunId) {
        var want = pendingRunId;
        pendingRunId = null;
        el.runFilter.value = "";
        renderRunOptions("");
        el.runSelect.value = want;
        var p = loadRun(want);
        var pn = window._pendingRunNode; window._pendingRunNode = null;
        if (pn) p.then(function(){ setTimeout(function(){ try{ var n = el.runGraph.querySelector('.run-node[data-label="' + CSS.escape(pn) + '"]'); if(n){ n.focus(); n.click(); n.scrollIntoView({block:"center", inline:"center"}); } }catch(_){}} , 300); });
        return p;
      }
      var wanted = renderRunOptions(el.runFilter.value);
      if (wanted) return loadRun(wanted);
      el.runStatus.textContent = "";
    })
    .catch(function (err) {
      el.runGraph.removeAttribute("aria-busy");
      showRunsError("Could not load runs: " + err.message);
    });
}

/* Failures land in #run-graph, which is a plain group — nothing would say
   them out loud. Routed through the status region so a failed Refresh is
   not silence. */
function showRunsError(message) {
  el.runGraph.textContent = "";
  var p = document.createElement("p");
  p.className = "run-empty";
  p.textContent = message;
  el.runGraph.appendChild(p);
  el.runStatus.textContent = message;
}

/* One way to open a named run, whether the view has loaded yet or not. */
function openRun(id) {
  try { history.replaceState(null, "", "#runs/" + encodeURIComponent(id)); } catch (_) {}
  if (viewLoaded.runs) {
    showView("runs", true);
    el.runFilter.value = "";
    renderRunOptions("");
    el.runSelect.value = id;
    return loadRun(id);
  }
  pendingRunId = id;
  showView("runs", true);
  return null;
}

function loadRun(id) {
  el.runGraph.textContent = "";
  skeletonRows(el.runGraph, 2);
  el.runStatus.textContent = "Loading run " + id + "…";
  // Every route into a run ends here — the select, a row, the palette, a
  // #runs/<id> deep link — so the list's highlight is set once, here.
  markSelectedRunRow(id);
  return fetch("/api/runs/" + encodeURIComponent(id))
    .then(readJson)
    .then(function (g) {
      el.runGraph.textContent = "";
      el.runGraph.removeAttribute("aria-busy");
      populateCompareSelects();
      drawRun(g);
      // The graph itself makes completion visible, but this live region is
      // also the small floating status shown while a run loads. Leaving the
      // loading copy behind makes a finished graph still look in flight.
      el.runStatus.textContent = "";
    })
    .catch(function (err) {
      var msg = err && err.message ? err.message : "unknown error";
      showRunsError(msg === "graph read failed"
        ? "Could not load that run. It may have been removed; open Runs to pick another."
        : "Could not load that run: " + msg);
    });
}
function populateCompareSelects(){
  var a=document.getElementById("run-compare-a"), b=document.getElementById("run-compare-b");
  if(!a||!b) return;
  var opts = allRuns.map(function(r){ var o=document.createElement("option"); o.value=r.run_id; o.textContent=runLabel(r); return o; });
  // keep selections if already set
  var keepA=a.value, keepB=b.value;
  a.textContent=""; b.textContent="";
  opts.forEach(function(o){ a.appendChild(o.cloneNode(true)); b.appendChild(o.cloneNode(true)); });
  if(keepA) a.value=keepA; else if(allRuns[0]) a.value=allRuns[0].run_id;
  if(keepB) b.value=keepB; else if(allRuns[1]) b.value=allRuns[1].run_id;
  document.getElementById("run-compare").hidden = allRuns.length < 2;
}
function diffRuns(aId, bId){
  var status=document.getElementById("run-compare-status"), clearBtn=document.getElementById("run-compare-clear");
  if(!aId||!bId){ if(status) status.textContent="Pick two runs"; return; }
  if(aId===bId){ if(status) status.textContent="Pick two different runs"; return; }
  if(status) status.textContent="Comparing…";
  Promise.all([fetch("/api/runs/"+encodeURIComponent(aId)).then(readJson), fetch("/api/runs/"+encodeURIComponent(bId)).then(readJson)]).then(function(pair){
    var ga=pair[0], gb=pair[1];
    var aNodes={}, bNodes={};
    (ga.nodes||[]).forEach(function(n){ var k=n.label||n.detail||n.kind; aNodes[k]=(aNodes[k]||0)+1; });
    (gb.nodes||[]).forEach(function(n){ var k=n.label||n.detail||n.kind; bNodes[k]=(bNodes[k]||0)+1; });
    var added=[], removed=[], changed=[];
    Object.keys(bNodes).forEach(function(k){ if(!aNodes[k]) added.push(k); });
    Object.keys(aNodes).forEach(function(k){ if(!bNodes[k]) removed.push(k); });
    (ga.nodes||[]).forEach(function(n){
      var k=n.label||n.detail||n.kind;
      var m=(gb.nodes||[]).find(function(x){ return (x.label||x.detail||x.kind)===k; });
      if(m && (m.ok!==n.ok || Math.abs((m.duration_ms||0)-(n.duration_ms||0))> Math.max(80, (n.duration_ms||0)*0.25))) changed.push(k + ": " + (m.ok===false?"failed":"") + " " + (n.duration_ms||0)+"ms → "+(m.duration_ms||0)+"ms");
    });
    // Re-render current graph with highlights
    drawRun(ga);
    setTimeout(function(){
      added.forEach(function(k){ el.runGraph.querySelectorAll(".run-node").forEach(function(el2){ if((el2.getAttribute("data-label")||"").indexOf(k.slice(0,16))!==-1) el2.style.outline="2px solid var(--ok)"; }); });
      removed.forEach(function(k){ el.runGraph.querySelectorAll(".run-node").forEach(function(el2){ if((el2.getAttribute("data-label")||"").indexOf(k.slice(0,16))!==-1) el2.setAttribute("data-ok","false"); }); });
      changed.forEach(function(k){ var lab=k.split(": ")[0]; el.runGraph.querySelectorAll(".run-node").forEach(function(el2){ if((el2.getAttribute("data-label")||"").indexOf(lab.slice(0,16))!==-1) el2.style.boxShadow="0 0 0 2px var(--warn)"; }); });
    }, 260);
    if(status) status.textContent = added.length+" added · "+removed.length+" removed · "+changed.length+" changed";
    if(clearBtn) clearBtn.hidden=false;
    el.runDetail.hidden=false; el.runDetail.textContent="";
    var pre=document.createElement("pre"); pre.style.whiteSpace="pre-wrap"; pre.style.fontSize="12px";
    pre.textContent = "A: "+aId+"\nB: "+bId+"\n\n+ added ("+added.length+"):\n"+added.join("\n")+"\n\n- removed ("+removed.length+"):\n"+removed.join("\n")+"\n\n~ changed ("+changed.length+"):\n"+changed.join("\n");
    el.runDetail.appendChild(pre);
  }).catch(function(e){ if(status) status.textContent="Diff failed: "+e.message; });
}

/* The run-graph layout (lib/graph.js, ~18 KB) is only ever reached through
   drawRun, and only the Runs view draws. It loads on first draw the way the
   d3-dag bundle it feeds already does, so a visit that stays in chat never
   fetches it. `graphModule` stays null until then; drawRun is the one gate,
   because every other entry point here (showNodeDetail's metrics line, the
   Copy summary button) is reachable only from a graph that has been drawn. */
var graphModule = null;
var graphModulePromise = null;
function loadGraphModule() {
  if (!graphModulePromise) {
    graphModulePromise = import("../lib/graph.js").then(function (m) {
      graphModule = m;
      return m;
    }, function (err) {
      graphModulePromise = null; // a failed chunk import must be retryable
      throw err;
    });
  }
  return graphModulePromise;
}
function metricsFor(node) { return graphModule.metricsFor(node); }
function buildStages(nodes) { return graphModule.buildStages(nodes); }

var lastGraph = null;
var lastBuilt = null;
/* drawRun hangs pan/minimap handlers off window; each redraw builds a fresh
   canvas, so the previous set is aborted here or every redraw would leak five
   listeners plus the detached subtree their closures retain. */
var drawRunListeners = null;
var resizeTimer = null;
var resizeHandler = function () {
  if (resizeTimer) window.clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(function () {
    if (lastGraph) drawRun(lastGraph);
  }, 150);
};
window.addEventListener("resize", resizeHandler);
// Cleaned up on pagehide to avoid handler leak after bfcache restore
window.addEventListener("pagehide", function () {
  window.removeEventListener("resize", resizeHandler);
  if (resizeTimer) window.clearTimeout(resizeTimer);
});

function drawRun(g) {
  // The layout helpers arrive with the chunk above. Re-enter once it has,
  // and say so in the graph panel if it never does, so a dead chunk is a
  // visible failure rather than a Runs view that silently stays empty.
  if (!graphModule) {
    loadGraphModule().then(function () { drawRun(g); }).catch(function () {
      showLoadError(el.runGraph, "Could not load the run graph.", function () { drawRun(g); });
    });
    return;
  }
  // Redraws also happen on window resize (same run, new layout) — only
  // close the detail panel when the run itself actually changed, not on
  // every resize while someone's mid-read of a node's output.
  if (!lastGraph || lastGraph.run_id !== g.run_id) {
    el.runDetail.hidden = true;
    el.runDetail.textContent = "";
  }
  lastGraph = g;
  if (drawRunListeners) drawRunListeners.abort();
  drawRunListeners = new AbortController();
  var winSignal = drawRunListeners.signal;
  el.runGraph.textContent = "";
  var nodes = g.nodes || [];

  var head = document.createElement("div");
  head.className = "run-head";
  head.style.display = "flex"; head.style.flexWrap = "wrap"; head.style.gap = "var(--space-2)"; head.style.alignItems = "center";
  var headId = document.createElement("span"); headId.textContent = g.run_id; headId.style.fontWeight = "600"; head.appendChild(headId);
  if (g.provider) { var hp = document.createElement("span"); hp.className = "tool-tag"; hp.textContent = g.provider; head.appendChild(hp); }
  var hm = document.createElement("span"); hm.className = "meta"; hm.textContent = g.duration_ms + "ms · " + g.total_prompt_tokens + " prompt + " + g.total_completion_tokens + " completion"; head.appendChild(hm);
  if (g.task) { var ht = document.createElement("span"); ht.className = "meta"; ht.style.flexBasis = "100%"; ht.textContent = g.task; head.appendChild(ht); }
  var copyHead = document.createElement("button"); copyHead.type = "button"; copyHead.className = "secondary"; copyHead.textContent = "Copy id"; upgradePfButton(copyHead);
  copyHead.addEventListener("click", function(){ try{ navigator.clipboard.writeText(g.run_id); copyHead.textContent="Copied"; setTimeout(function(){ copyHead.textContent="Copy id"; }, 1200);}catch(_){} });
  head.appendChild(copyHead);
  var copyLink = document.createElement("button"); copyLink.type = "button"; copyLink.className = "secondary"; copyLink.textContent = "Copy link"; upgradePfButton(copyLink);
  copyLink.title = "Copy deep-link to this run — add ?node= to pin this exact graph position";
  copyLink.addEventListener("click", function(){
    var sel = el.runGraph.querySelector(".run-node.selected");
    var nodePart = sel && sel.getAttribute("data-label") ? "?node=" + encodeURIComponent(sel.getAttribute("data-label")) : "";
    var u = location.origin + location.pathname + "#runs/" + encodeURIComponent(g.run_id) + nodePart;
    try{ navigator.clipboard.writeText(u); copyLink.textContent="Copied"; setTimeout(function(){ copyLink.textContent="Copy link"; }, 1200);}catch(_){ copyText(u, copyLink, "Copy link", head); }
  });
  head.appendChild(copyLink);
  var exportBtn = document.createElement("button"); exportBtn.type = "button"; exportBtn.className = "secondary"; exportBtn.textContent = "Export .html"; upgradePfButton(exportBtn);
  exportBtn.title = "Download this run as a self-contained HTML file";
  exportBtn.addEventListener("click", function(){
    try{
      var svg = el.runGraph.querySelector("svg.run-edges");
      var svgHtml = svg ? new XMLSerializer().serializeToString(svg) : "";
      var detailHtml = el.runDetail.hidden ? "" : el.runDetail.innerHTML;
      // Everything interpolated here is run data — the task is whatever the
      // operator or a parent agent typed, the run id is a server-side string
      // — and this is raw string concatenation, not DOM building, so it needs
      // explicit escaping. It did not have it: a task containing markup was
      // written straight into <title>, <h1> and <p> of a file the browser then
      // opens from a blob URL.
      //
      // The JSON dump below looked escaped and was not, which is how the gap
      // in the header stayed invisible: it hand-rolled `.replace(/</g,"&lt;")`,
      // a second escaper covering one of the five characters that matter. `<`
      // alone does keep markup out of a <pre>, but leaving `&` means every
      // entity a run's own text contains is decoded on the way back out, so a
      // tool result holding the literal text "&lt;script&gt;" was shown as
      // "<script>". One escaper, `core/utils.js`'s escapeHtml, at every
      // interpolation site including this one.
      var esc = escapeHtml;
      // The exported graph is the second artefact that leaves the machine
      // (`clanker session export` is the other), so it carries the same
      // Control Cabinet vocabulary rather than a default sans on a grey
      // rounded box: RAL panel greys, 3px machined edges, engraved mono for
      // the readings. Values match tools/zig/session_export_logic.zig, which
      // took them from themes/light.json and themes/dark.json — both files
      // are self-contained by contract and cannot read the theme store.
      var exportCss = ":root{color-scheme:light dark;--bg:#dcd9d1;--fg:#1b1c18;--muted:#4f534b;--edge:#b9b5aa;--card:#eeebe4;--code:#d4d0c6}"
        + "@media (prefers-color-scheme:dark){:root{--bg:#171916;--fg:#e8eae5;--muted:#a3aaa1;--edge:#454a44;--card:#232622;--code:#121411}}"
        + "body{font-family:ui-sans-serif,system-ui;background:var(--bg);color:var(--fg);padding:1.2rem;max-width:70rem;margin:auto}"
        + "h1{font:700 1.1rem/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;letter-spacing:.04em;word-break:break-all}"
        + "body > p{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.8rem;color:var(--muted)}"
        + "hr{border:0;border-top:1px solid var(--edge)}"
        + "pre{white-space:pre-wrap;word-break:break-word;background:var(--code);border:1px solid var(--edge);padding:0.8rem;border-radius:3px;overflow:auto;font-size:.8rem}"
        + "svg{max-width:100%;height:auto}";
      var html = "<!doctype html><meta charset=utf-8><title>" + esc(g.run_id) + "</title><style>" + exportCss + "</style><h1>" + esc(g.run_id) + "</h1><p>" + esc(g.task||"") + " · " + esc(g.duration_ms) + "ms · " + esc(g.total_prompt_tokens) + " prompt + " + esc(g.total_completion_tokens) + " completion</p><div>" + svgHtml + "</div><hr><div>" + detailHtml + "</div><pre>" + esc(JSON.stringify(g, null, 2)) + "</pre>";
      var blob = new Blob([html], {type:"text/html"});
      var url = URL.createObjectURL(blob);
      var a = document.createElement("a"); a.href = url; a.download = g.run_id + ".html";
      document.body.appendChild(a); a.click(); a.remove(); setTimeout(function(){ URL.revokeObjectURL(url); }, 1000);
    }catch(_){ el.runStatus.textContent = "Export failed"; }
  });
  head.appendChild(exportBtn);
  if (g.parent_run_id) {
    var par = document.createElement("button"); par.type = "button"; par.className = "secondary"; par.textContent = "↑ Parent " + g.parent_run_id.slice(0,8); upgradePfButton(par);
    par.title = "Open parent run " + g.parent_run_id;
    par.addEventListener("click", function(){ openRun(g.parent_run_id); });
    head.appendChild(par);
  }
  el.runGraph.appendChild(head);

  if (!nodes.length) {
    var empty = document.createElement("p");
    empty.className = "run-empty";
    empty.textContent = "This run recorded no nodes.";
    el.runGraph.appendChild(empty);
    return;
  }

  var built = buildStages(nodes);
  lastBuilt = built;
  // Duration bars are scaled against the slowest node, not the run total:
  // one long LLM call would otherwise flatten every tool call to an
  // invisible sliver.
  var slowest = nodes.reduce(function (m, n) {
    return n.kind === "final" ? m : Math.max(m, n.duration_ms || 0);
  }, 0) || 1;

  // The SVG arrows that show branching/convergence are aria-hidden (each
  // node's own aria-label already covers its kind/name/metrics); without
  // this, a screen-reader user gets a flat list of nodes with no sense of
  // which tool calls ran in parallel or what fed into what.
  var summary = document.createElement("p");
  summary.className = "sr-only";
  summary.textContent = graphSummaryText(built);
  el.runGraph.appendChild(summary);

  var graphSearch = document.createElement("div");
  graphSearch.className = "run-graph-search";
  graphSearch.style.display = "flex"; graphSearch.style.gap = "var(--space-3)"; graphSearch.style.marginBottom = "var(--space-2)"; graphSearch.style.flexWrap = "wrap"; graphSearch.style.alignItems = "center";
  var graphSearchInput = document.createElement("input");
  graphSearchInput.type = "search"; graphSearchInput.placeholder = "Filter nodes (e.g. read_file, grep)…  —  / to focus";
  graphSearchInput.setAttribute("aria-label", "Filter graph nodes — press / to focus, n/N to step matches, F failed, j/k iterations, arrows walk nodes");
  graphSearchInput.title = "Filter nodes — / focuses, n/N next match, F failed, j/k next iteration";
  graphSearchInput.style.flex = "1"; graphSearchInput.style.minWidth = "12rem";
  var graphNextBtn = document.createElement("button"); graphNextBtn.type = "button"; graphNextBtn.className = "secondary"; graphNextBtn.textContent = "Next"; upgradePfButton(graphNextBtn);
  graphNextBtn.title = "Next match (n)";
  var graphClearBtn = document.createElement("button"); graphClearBtn.type = "button"; graphClearBtn.className = "secondary"; graphClearBtn.textContent = "Clear"; upgradePfButton(graphClearBtn);
  graphClearBtn.title = "Clear filter";
  var graphFitBtn = document.createElement("button"); graphFitBtn.type = "button"; graphFitBtn.className = "secondary"; graphFitBtn.textContent = "Fit"; upgradePfButton(graphFitBtn);
  graphFitBtn.title = "Fit graph to view (0)";
  graphSearch.appendChild(graphSearchInput); graphSearch.appendChild(graphNextBtn); graphSearch.appendChild(graphClearBtn); graphSearch.appendChild(graphFitBtn);
  var graphHint = document.createElement("span"); graphHint.className = "meta"; graphHint.textContent = "/ filter · n next · F failed · j/k iter · arrows walk · +/− zoom · click node to pin link";
  graphHint.style.fontSize = "11px"; graphHint.style.opacity = "0.75"; graphHint.style.flexBasis = "100%";
  graphSearch.appendChild(graphHint);
  el.runGraph.appendChild(graphSearch);
  // Trello/Slack-style focus filters — dim non-matches so dense graphs stay scannable
  var _kindFilter = (function(){ try{ return localStorage.getItem("clanker.graphKind") || ""; }catch(_){ return ""; } })();
  var _initSearch = (function(){ try{ return localStorage.getItem("clanker.graphSearch") || ""; }catch(_){ return ""; } })();
  var graphKindBar = document.createElement("div");
  graphKindBar.className = "run-kind-filter"; graphKindBar.style.display = "flex"; graphKindBar.style.gap = "var(--space-1)"; graphKindBar.style.flexWrap = "wrap"; graphKindBar.style.marginBottom = "var(--space-2)";
  graphKindBar.setAttribute("role", "group"); graphKindBar.setAttribute("aria-label", "Filter by node kind");
  [{k:"",label:"All"},{k:"llm",label:"LLM"},{k:"tool",label:"Tools"},{k:"final",label:"Answer"},{k:"failed",label:"Failed"}].forEach(function(opt){
    var b = document.createElement("button"); b.type = "button"; b.className = "secondary"; b.textContent = opt.label; upgradePfButton(b);
    b.dataset.kind = opt.k; b.setAttribute("aria-pressed", String(opt.k === _kindFilter));
    if (opt.k === "failed") b.title = "Only failed nodes";
    b.addEventListener("click", function(){
      _kindFilter = opt.k;
      try{ localStorage.setItem("clanker.graphKind", _kindFilter); }catch(_){}
      graphKindBar.querySelectorAll("button").forEach(function(x){ x.setAttribute("aria-pressed", String(x.dataset.kind === _kindFilter)); });
      _matchIdx = -1; doLayout(_searchQ);
    });
    graphKindBar.appendChild(b);
  });
  if (_initSearch) graphSearchInput.value = _initSearch;
  el.runGraph.appendChild(graphKindBar);
  // Codex-style breadcrumb: iteration / step chips + keyboard tour
  var crumb = document.createElement("div");
  crumb.className = "run-crumbs"; crumb.style.display = "flex"; crumb.style.gap = "var(--space-1)"; crumb.style.flexWrap = "wrap"; crumb.style.marginBottom = "var(--space-2)";
  crumb.setAttribute("role", "navigation"); crumb.setAttribute("aria-label", "Iterations");
  built.stages.forEach(function(st, idx){
    var chip = document.createElement("button");
    chip.type = "button"; chip.className = "secondary"; chip.textContent = "iter " + st.iteration; upgradePfButton(chip);
    chip.title = st.iteration + " · " + (st.llm.label || "llm") + (st.tools.length ? " · " + st.tools.map(function(t){ return t.label; }).join(", ") : "");
    chip.addEventListener("click", function(){
      var tags = canvas.querySelectorAll(".run-iter-tag");
      for (var ti=0; ti<tags.length; ti++) if (tags[ti].textContent.trim() === String(st.iteration)) {
        var x = parseFloat(tags[ti].style.left) + 20;
        var y = parseFloat(tags[ti].style.top) + 11;
        canvas.scrollLeft = Math.max(0, x - canvas.clientWidth/2);
        canvas.scrollTop = Math.max(0, y - canvas.clientHeight/2);
        break;
      }
    });
    crumb.appendChild(chip);
  });
  if (built.stages.length) el.runGraph.appendChild(crumb);
  // Time scrubber / playback — iteration stepper (Codex/Kimi parity)
  if (built.stages.length > 1) {
    var maxIter = Math.max.apply(null, built.stages.map(function(s){ return s.iteration; }));
    var minIter = Math.min.apply(null, built.stages.map(function(s){ return s.iteration; }));
    var scrubWrap = document.createElement("div");
    scrubWrap.style.display = "flex"; scrubWrap.style.alignItems = "center"; scrubWrap.style.gap = "var(--space-3)"; scrubWrap.style.marginBottom = "var(--space-2)";
    var scrubLabel = document.createElement("span"); scrubLabel.className = "meta"; scrubLabel.textContent = "Scrub:"; scrubWrap.appendChild(scrubLabel);
    var scrub = document.createElement("input"); scrub.type = "range"; scrub.min = String(minIter); scrub.max = String(maxIter); scrub.value = String(maxIter); scrub.step = "1";
    scrub.setAttribute("aria-label", "Scrub iterations"); scrub.style.flex = "1";
    var scrubOut = document.createElement("span"); scrubOut.className = "meta"; scrubOut.textContent = "iter " + maxIter + " / " + maxIter;
    scrubWrap.appendChild(scrub); scrubWrap.appendChild(scrubOut);
    scrub.addEventListener("input", function(){
      var v = parseInt(scrub.value, 10);
      scrubOut.textContent = "iter " + v + " / " + maxIter;
      // dim nodes past scrub point so you can see how the run grew
      canvas.querySelectorAll(".run-node").forEach(function(n){
        var nodeIter = parseInt(n.getAttribute("data-iter") || "0", 10);
        if (isNaN(nodeIter)) return;
        n.style.opacity = (nodeIter > v) ? "0.2" : "";
      });
    });
    el.runGraph.appendChild(scrubWrap);
  }

  var canvas = document.createElement("div");
  canvas.className = "run-canvas";
  canvas.tabIndex = 0;
  canvas.setAttribute("aria-label", "Scrollable execution graph — drag to pan, Ctrl+wheel to zoom, +/- keys, search to highlight");
  (function(){
    var isPanning = false, startX = 0, startY = 0, startScrollLeft = 0, startScrollTop = 0;
    canvas.addEventListener("mousedown", function(e){
      if (e.target.closest && e.target.closest(".run-node")) return;
      isPanning = true; startX = e.clientX; startY = e.clientY; startScrollLeft = canvas.scrollLeft; startScrollTop = canvas.scrollTop;
      canvas.style.cursor = "grabbing";
      e.preventDefault();
    });
    window.addEventListener("mouseup", function(){ if(isPanning){ isPanning = false; canvas.style.cursor = ""; } }, { signal: winSignal });
    window.addEventListener("mousemove", function(e){
      if (!isPanning) return;
      canvas.scrollLeft = startScrollLeft - (e.clientX - startX);
      canvas.scrollTop = startScrollTop - (e.clientY - startY);
    }, { signal: winSignal });
    canvas.addEventListener("wheel", function(e){
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        if (e.deltaY < 0) zoomInBtn.click(); else if (e.deltaY > 0) zoomOutBtn.click();
      }
    }, { passive: false });
  })();
  var zoomWrap = document.createElement("div");
  zoomWrap.style.display = "flex"; zoomWrap.style.gap = "var(--space-2)"; zoomWrap.style.marginTop = "var(--space-2)";
  var zoomInBtn = document.createElement("button"); zoomInBtn.type = "button"; zoomInBtn.className = "secondary"; zoomInBtn.textContent = "+ Zoom"; upgradePfButton(zoomInBtn);
  var zoomOutBtn = document.createElement("button"); zoomOutBtn.type = "button"; zoomOutBtn.className = "secondary"; zoomOutBtn.textContent = "− Zoom"; upgradePfButton(zoomOutBtn);
  var zoomResetBtn = document.createElement("button"); zoomResetBtn.type = "button"; zoomResetBtn.className = "secondary"; zoomResetBtn.textContent = "Reset"; upgradePfButton(zoomResetBtn);
  var zoomLevel = 1;
  function applyZoom(){ canvas.style.transform = zoomLevel === 1 ? "" : "scale(" + zoomLevel + ")"; canvas.style.transformOrigin = "top left"; }
  zoomInBtn.addEventListener("click", function(){ zoomLevel = Math.min(1.8, zoomLevel + 0.15); applyZoom(); });
  zoomOutBtn.addEventListener("click", function(){ zoomLevel = Math.max(0.5, zoomLevel - 0.15); applyZoom(); });
  zoomResetBtn.addEventListener("click", function(){ zoomLevel = 1; applyZoom(); });
  zoomWrap.appendChild(zoomInBtn); zoomWrap.appendChild(zoomOutBtn); zoomWrap.appendChild(zoomResetBtn);
  el.runGraph.appendChild(canvas);
  el.runGraph.appendChild(zoomWrap);

  var minimap = document.createElement("div");
  minimap.className = "run-minimap"; minimap.hidden = true;
  minimap.setAttribute("role", "navigation"); minimap.setAttribute("aria-label", "Minimap — click to jump, drag viewport to pan");
  minimap.title = "Click to jump · drag viewport to pan";
  var mmLabel = document.createElement("span"); mmLabel.className = "run-minimap-label"; mmLabel.textContent = "map"; minimap.appendChild(mmLabel);
  var mmCanvas = document.createElement("canvas"); mmCanvas.width = 148; mmCanvas.height = 90; minimap.insertBefore(mmCanvas, mmLabel.nextSibling);
  var mmViewport = document.createElement("div"); mmViewport.className = "run-minimap-viewport";
  minimap.appendChild(mmViewport);
  canvas.appendChild(minimap);
  // Content size and node positions are cached on layout. Scroll only
  // updates the viewport rect, coalesced to one rAF, so it never walks
  // the node list or forces layout.
  var mmSW = 1, mmSH = 1, mmRaf = 0, mmNodes = [], mmEdges = [];
  function mmToken(name, fallback) {
    try { return (getComputedStyle(document.documentElement).getPropertyValue(name) || "").trim() || fallback; }
    catch (_) { return fallback; }
  }
  function measureMinimap(){
    try { mmSW = Math.max(1, canvas.scrollWidth); mmSH = Math.max(1, canvas.scrollHeight); }
    catch(_){ mmSW = 1; mmSH = 1; }
  }
  function rebuildMinimapCache(){
    measureMinimap();
    mmNodes = [];
    canvas.querySelectorAll(".run-node").forEach(function(n){
      var lx = parseFloat(n.style.left), ly = parseFloat(n.style.top);
      mmNodes.push({
        el: n,
        x: isFinite(lx) ? lx : 0,
        y: isFinite(ly) ? ly : 0,
        kind: n.getAttribute("data-kind") || "",
        ok: n.getAttribute("data-ok"),
        selected: n.classList.contains("selected"),
        highlight: n.hasAttribute("data-highlight")
      });
    });
    mmEdges = [];
    try {
      canvas.querySelectorAll("svg.run-edges path[data-edge]").forEach(function(p){
        var d = p.getAttribute("d") || "";
        var m = d.match(/M\s*([0-9.\-]+),([0-9.\-]+)\s*L\s*([0-9.\-]+),([0-9.\-]+)/);
        if (!m) return;
        mmEdges.push({ x1: parseFloat(m[1]), y1: parseFloat(m[2]), x2: parseFloat(m[3]), y2: parseFloat(m[4]) });
      });
    } catch (_) {}
  }
  function paintMinimap(){
    try{
      var ctx = mmCanvas.getContext("2d");
      if (!ctx) return;
      ctx.clearRect(0,0,mmCanvas.width, mmCanvas.height);
      var sw = mmSW, sh = mmSH;
      var accent = mmToken("--accent", "#1d5c9e");
      var ok = mmToken("--ok", "#117a3a");
      var danger = mmToken("--danger", "#a72920");
      var fg = mmToken("--fg", "#111");
      var muted = mmToken("--fg-muted", "#888");
      ctx.strokeStyle = muted;
      ctx.globalAlpha = 0.35;
      ctx.lineWidth = 0.7;
      mmEdges.forEach(function(e){
        ctx.beginPath();
        ctx.moveTo((e.x1 / sw) * mmCanvas.width, (e.y1 / sh) * mmCanvas.height);
        ctx.lineTo((e.x2 / sw) * mmCanvas.width, (e.y2 / sh) * mmCanvas.height);
        ctx.stroke();
      });
      ctx.globalAlpha = 0.75;
      mmNodes.forEach(function(n){
        var x = (n.x / sw) * mmCanvas.width;
        var y = (n.y / sh) * mmCanvas.height;
        var w = 6, h = 4;
        if (n.kind === "llm") ctx.fillStyle = accent;
        else if (n.kind === "tool") ctx.fillStyle = ok;
        else if (n.kind === "final") ctx.fillStyle = fg;
        else ctx.fillStyle = muted;
        if (n.ok === "false") ctx.fillStyle = danger;
        if (n.selected) { ctx.fillStyle = accent; ctx.globalAlpha = 1; w = 7; h = 5; }
        else if (n.highlight) { ctx.fillStyle = accent; ctx.globalAlpha = 0.45; }
        ctx.fillRect(x, y, w, h);
        ctx.globalAlpha = 0.75;
      });
      ctx.globalAlpha = 1;
    }catch(_){}
  }
  function updateMinimapViewport(){
    var cw = canvas.clientWidth, ch = canvas.clientHeight;
    var needsMap = mmSW > cw + 8 || mmSH > ch + 8;
    minimap.hidden = !needsMap;
    if (minimap.hidden) return;
    var sx = canvas.scrollLeft / Math.max(1, mmSW - cw);
    var sy = canvas.scrollTop / Math.max(1, mmSH - ch);
    var vw = cw / mmSW * 100;
    var vh = ch / mmSH * 100;
    mmViewport.style.left = (sx * (100 - vw)) + "%";
    mmViewport.style.top = (sy * (100 - vh)) + "%";
    mmViewport.style.width = Math.max(12, vw) + "%";
    mmViewport.style.height = Math.max(12, vh) + "%";
  }
  function updateMinimap(){
    rebuildMinimapCache();
    if (mmSW > canvas.clientWidth + 8 || mmSH > canvas.clientHeight + 8) paintMinimap();
    updateMinimapViewport();
  }
  function scheduleMinimap(){
    if (mmRaf) return;
    mmRaf = requestAnimationFrame(function(){
      mmRaf = 0;
      updateMinimapViewport();
    });
  }
  canvas.addEventListener("scroll", scheduleMinimap, { passive: true });
  minimap.addEventListener("click", function(e){
    if (e.target === mmViewport) return;
    var rect = minimap.getBoundingClientRect();
    var px = (e.clientX - rect.left) / rect.width;
    var py = (e.clientY - rect.top) / rect.height;
    var cx = px * mmSW, cy = py * mmSH;
    var best = null, bestD = Infinity;
    mmNodes.forEach(function(n){
      var d = Math.hypot(n.x - cx, n.y - cy);
      if (d < bestD) { bestD = d; best = n.el; }
    });
    if (best && bestD < 60) { best.focus(); best.click(); best.scrollIntoView({block:"center", inline:"center"}); return; }
    canvas.scrollLeft = px * (mmSW - canvas.clientWidth);
    canvas.scrollTop = py * (mmSH - canvas.clientHeight);
  });
  // drag viewport to pan
  (function(){
    var dragging = false, startX = 0, startY = 0, startSL = 0, startST = 0;
    mmViewport.addEventListener("mousedown", function(e){
      dragging = true; startX = e.clientX; startY = e.clientY; startSL = canvas.scrollLeft; startST = canvas.scrollTop;
      e.preventDefault(); e.stopPropagation();
    });
    window.addEventListener("mousemove", function(e){
      if (!dragging) return;
      var rect = minimap.getBoundingClientRect();
      var dxRatio = (e.clientX - startX) / rect.width;
      var dyRatio = (e.clientY - startY) / rect.height;
      canvas.scrollLeft = startSL + dxRatio * canvas.scrollWidth;
      canvas.scrollTop = startST + dyRatio * canvas.scrollHeight;
    }, { signal: winSignal });
    window.addEventListener("mouseup", function(){ dragging = false; }, { signal: winSignal });
  })();
  // keep in sync after layout / resize
  window.addEventListener("resize", updateMinimap, { signal: winSignal });
  // Fit button
  graphFitBtn.addEventListener("click", function(){
    canvas.scrollLeft = 0; canvas.scrollTop = 0;
    // also reset zoom if api exposed
    try{ var ev = new KeyboardEvent("keydown", { key: "0" }); canvas.dispatchEvent(ev); }catch(_){}
    updateMinimap();
  });

  function syncGraphUrl(){
    try{
      var rawHash = location.hash || "";
      var parsed = parseRunsHash(rawHash) || { id: (lastGraph ? lastGraph.run_id : ""), search:"", kind:"", node:"" };
      var base = "#runs/" + encodeURIComponent(lastGraph ? lastGraph.run_id : parsed.id);
      if (!lastGraph || !lastGraph.run_id) base = rawHash.split("?")[0] || base;
      var params = [];
      if (_searchQ) params.push("search=" + encodeURIComponent(_searchQ));
      else if (parsed.search && !canvas.querySelector(".run-node")) params.push("search=" + encodeURIComponent(parsed.search));
      if (_kindFilter) params.push("kind=" + encodeURIComponent(_kindFilter));
      else if (parsed.kind && !canvas.querySelector(".run-node")) params.push("kind=" + encodeURIComponent(parsed.kind));
      var sel = canvas.querySelector(".run-node.selected");
      var lbl = sel ? sel.getAttribute("data-label") : (parsed.node || window._pendingRunNode || null);
      if (lbl) params.push("node=" + encodeURIComponent(lbl));
      var hash = base + (params.length ? "?" + params.join("&") : "");
      if (location.hash !== hash) history.replaceState(null, "", hash);
    }catch(_){}
  }
  function doLayout(q){
    loadD3().then(function () {
      if (canvas.isConnected) layoutGraph(canvas, built, slowest, { searchQuery: q || "", kindFilter: _kindFilter, statusEl: el.runStatus, minimap: minimap, onSelect: function(k,n){ showNodeDetail(k,n); syncGraphUrl(); } });
      try{ updateMinimap(); paintMinimap(); }catch(_){}
      syncGraphUrl();
    }).catch(function (err) {
      var errEl = document.createElement("p");
      errEl.className = "run-empty";
      errEl.textContent = "Could not load the graph layout library: " + err.message;
      canvas.appendChild(errEl);
      el.runStatus.textContent = errEl.textContent;
    });
  }
  var _searchQ = "";
  var _matchIdx = -1;
  function focusNextMatch(){
    var matches = canvas.querySelectorAll('.run-node[data-match="true"]');
    if (!matches.length) return;
    _matchIdx = (_matchIdx + 1) % matches.length;
    matches[_matchIdx].focus();
    matches[_matchIdx].scrollIntoView({ block: "nearest", inline: "center" });
  }
  // An error lens — one button jumps to failed nodes
  var graphFailedBtn = document.createElement("button"); graphFailedBtn.type = "button"; graphFailedBtn.className = "secondary"; graphFailedBtn.textContent = "⚠ Failed"; upgradePfButton(graphFailedBtn);
  graphFailedBtn.title = "Next failed node";
  graphSearch.appendChild(graphFailedBtn);
  function focusNextFailed(){
    var fails = canvas.querySelectorAll('.run-node[data-ok="false"]');
    if (!fails.length) return;
    _matchIdx = (_matchIdx + 1) % fails.length;
    fails[_matchIdx].focus(); fails[_matchIdx].scrollIntoView({ block: "nearest", inline: "center" });
    fails[_matchIdx].click();
  }
  graphFailedBtn.addEventListener("click", focusNextFailed);
  _searchQ = _initSearch || "";
  graphSearchInput.addEventListener("input", function(){
    _searchQ = graphSearchInput.value.trim();
    try{ localStorage.setItem("clanker.graphSearch", graphSearchInput.value); }catch(_){}
    _matchIdx = -1;
    doLayout(_searchQ);
  });
  graphNextBtn.addEventListener("click", focusNextMatch);
  graphClearBtn.addEventListener("click", function(){ graphSearchInput.value = ""; _searchQ = ""; _matchIdx = -1; try{ localStorage.removeItem("clanker.graphSearch"); }catch(_){} doLayout(""); graphSearchInput.focus(); });
  // j/k step tour between iterations
  var _iterIdx = 0;
  function focusIter(dir){
    var chips = crumb.querySelectorAll("button");
    if (!chips.length) return;
    _iterIdx = (_iterIdx + dir + chips.length) % chips.length;
    chips[_iterIdx].focus();
    chips[_iterIdx].click();
  }
  canvas.addEventListener("keydown", function(e){
    if (document.activeElement === graphSearchInput) return;
    if (e.key === "ArrowDown" || e.key === "ArrowRight") {
      e.preventDefault();
      var nodes = Array.prototype.slice.call(canvas.querySelectorAll(".run-node"));
      if (!nodes.length) return;
      var at = nodes.indexOf(document.activeElement);
      var nxt = at === -1 ? 0 : Math.min(nodes.length - 1, at + 1);
      nodes[nxt].focus();
      return;
    }
    if (e.key === "ArrowUp" || e.key === "ArrowLeft") {
      e.preventDefault();
      var nodes2 = Array.prototype.slice.call(canvas.querySelectorAll(".run-node"));
      if (!nodes2.length) return;
      var at2 = nodes2.indexOf(document.activeElement);
      var prv = at2 <= 0 ? 0 : at2 - 1;
      nodes2[prv].focus();
      return;
    }
    if (e.key === "+" || e.key === "=") { e.preventDefault(); zoomInBtn.click(); }
    else if (e.key === "-" || e.key === "_") { e.preventDefault(); zoomOutBtn.click(); }
    else if (e.key === "0") { e.preventDefault(); zoomResetBtn.click(); }
    else if (e.key === "n" || e.key === "N") { if (_searchQ) { e.preventDefault(); focusNextMatch(); } else if (e.shiftKey || e.key === "N") { e.preventDefault(); focusNextFailed(); } }
    else if (e.key === "F" || e.key === "f") { if (e.shiftKey) { e.preventDefault(); focusNextFailed(); } }
    else if (e.key === "j") { e.preventDefault(); focusIter(1); }
    else if (e.key === "k") { e.preventDefault(); focusIter(-1); }
    else if (e.key === "Escape") { graphSearchInput.blur(); canvas.focus(); }
    else if (e.key === "/" && !e.ctrlKey && !e.metaKey) {
      e.preventDefault(); graphSearchInput.focus(); graphSearchInput.select();
    }
  });
  doLayout(_searchQ);
}

function graphSummaryText(built) { return graphModule.graphSummaryText(built); }
function layoutGraph(canvas, built, slowest, opts) { return graphModule.layoutGraph(canvas, built, slowest, opts); }

/* Rows for the edit-diff card: removed/added lines with a couple of context
   lines around the change, computed from an edit tool's old/new fragments.
   The fragments carry surrounding context by contract, so trimming the
   common prefix and suffix leaves exactly what the edit changed. */
function diffRows(oldText, newText) {
  var oldLines = oldText.replace(/\n$/, "").split("\n");
  var newLines = newText.replace(/\n$/, "").split("\n");
  var pre = 0;
  while (pre < oldLines.length && pre < newLines.length && oldLines[pre] === newLines[pre]) pre += 1;
  var oldEnd = oldLines.length;
  var newEnd = newLines.length;
  while (oldEnd > pre && newEnd > pre && oldLines[oldEnd - 1] === newLines[newEnd - 1]) { oldEnd -= 1; newEnd -= 1; }
  var rows = [];
  for (var i = Math.max(0, pre - 2); i < pre; i += 1) rows.push({ kind: "ctx", text: oldLines[i] });
  for (var i = pre; i < oldEnd; i += 1) rows.push({ kind: "del", text: oldLines[i] });
  for (var i = pre; i < newEnd; i += 1) rows.push({ kind: "add", text: newLines[i] });
  for (var i = oldEnd; i < Math.min(oldLines.length, oldEnd + 2); i += 1) rows.push({ kind: "ctx", text: oldLines[i] });
  return rows;
}

/* A collapsible tree for JSON-shaped node output — most tool results are
   JSON, and a flat highlighted blob makes a large payload (a big file
   listing, a nested API response) a wall of text with no way to collapse
   the part you don't care about. <details>/<summary> gives keyboard
   toggle and correct semantics for free, no custom ARIA needed. */
function buildJsonTree(value, keyLabel, depth) {  if (value === null) return jsonLeaf(keyLabel, "null", "hljs-literal");
  if (typeof value === "boolean") return jsonLeaf(keyLabel, String(value), "hljs-literal");
  if (typeof value === "number") return jsonLeaf(keyLabel, String(value), "hljs-number");
  if (typeof value === "string") return jsonLeaf(keyLabel, JSON.stringify(value), "hljs-string");
  if (Array.isArray(value)) {
    var items = value.map(function (v, i) { return [String(i), v]; });
    return jsonBranch(keyLabel, items, "[", "]", items.length + (items.length === 1 ? " item" : " items"), depth);
  }
  var entries = Object.keys(value).map(function (k) { return [k, value[k]]; });
  return jsonBranch(keyLabel, entries, "{", "}", entries.length + (entries.length === 1 ? " key" : " keys"), depth);
}

function jsonLeaf(keyLabel, text, valueClass) {
  var row = document.createElement("div");
  // .json-row's ::before reserves the same width as a branch's disclosure
  // triangle, so a leaf key and a branch key at one level start at the same
  // x. Without it the left edge jitters by 1em with no relation to nesting,
  // which is the one thing a tree's left edge is supposed to encode.
  row.className = "json-row";
  if (keyLabel !== null) {
    var k = document.createElement("span");
    k.className = "json-key";
    k.textContent = keyLabel + ": ";
    row.appendChild(k);
  }
  var v = document.createElement("span");
  v.className = valueClass;
  v.textContent = text;
  row.appendChild(v);
  return row;
}

function jsonBranch(keyLabel, entries, open, close, countLabel, depth) {
  if (!entries.length) return jsonLeaf(keyLabel, open + close, "json-empty");
  var details = document.createElement("details");
  details.className = "json-node";
  // Root and its immediate children open, everything below collapsed: a tree
  // that arrives fully expanded is the wall of text it was built to replace.
  // A closed branch still says what it holds ("{ 3 keys }"), so nothing is
  // hidden that the reader can't see they are choosing not to open.
  details.open = depth < 1;
  var summary = document.createElement("summary");
  if (keyLabel !== null) {
    var k = document.createElement("span");
    k.className = "json-key";
    k.textContent = keyLabel + ": ";
    summary.appendChild(k);
  }
  var brace = document.createElement("span");
  brace.className = "json-brace";
  brace.textContent = open + " " + countLabel + " " + close;
  summary.appendChild(brace);
  details.appendChild(summary);
  var body = document.createElement("div");
  body.className = "json-children";
  entries.forEach(function (pair) { body.appendChild(buildJsonTree(pair[1], pair[0], depth + 1)); });
  details.appendChild(body);
  return details;
}

/* Populates the persistent detail panel below the graph with whatever a
   clicked node recorded: not just its size, but the actual truncated tool
   result or model output (graph.zig's Node.output; earlier versions of
   recorded runs won't have it, hence the empty-state in the CSS). */
function showNodeDetail(kind, node) {
  el.runDetail.textContent = "";
  el.runDetail.hidden = false;

  var head = document.createElement("div");
  head.className = "run-detail-head";

  var titleWrap = document.createElement("span");
  var title = document.createElement("span");
  title.className = "run-detail-title";
  title.textContent = "";
  if (node.ok === false) title.appendChild(icon("strike", 12));
  title.appendChild(document.createTextNode(kind + " · " + (node.label || node.detail || kind)));
  titleWrap.appendChild(title);
  var meta = document.createElement("span");
  meta.className = "run-detail-meta";
  meta.textContent = "  " + metricsFor(node) + (node.detail ? "  ·  " + node.detail : "");
  titleWrap.appendChild(meta);
  head.appendChild(titleWrap);

  // Trello/Slack-style quick-jump: if output mentions another run, surface a Jump button in the header too
  (function(){
    var m = (node.output || "").match(/\[subagent run:\s*(sub-\d+)\]/);
    if (m) {
      var j = document.createElement("button"); j.type = "button"; j.className = "secondary"; j.textContent = "↗ " + m[1]; upgradePfButton(j);
      j.title = "Open sub-run " + m[1];
      j.addEventListener("click", function(){ openRun(m[1]); });
      head.appendChild(j);
    }
  })();
  var copyBtn = document.createElement("button");
  copyBtn.type = "button"; copyBtn.className = "secondary"; copyBtn.textContent = "Copy"; upgradePfButton(copyBtn);
  copyBtn.title = "Copy this node's output";
  copyBtn.addEventListener("click", function(){
    var t = node.output || "";
    try{ navigator.clipboard.writeText(t); copyBtn.textContent = "Copied"; setTimeout(function(){ copyBtn.textContent="Copy"; }, 1200); }catch(_){ copyText(t, copyBtn, "Copy", out); }
  });
  head.appendChild(copyBtn);
  var closeBtn = document.createElement("button");
  closeBtn.type = "button";
  closeBtn.className = "secondary run-detail-close";
  closeBtn.textContent = "Close";
  upgradePfButton(closeBtn);
  closeBtn.addEventListener("click", closeNodeDetail);
  head.appendChild(closeBtn);

  el.runDetail.appendChild(head);

  /* The server records only the first `output_preview_cap` bytes of a node's
     result (graph.zig), and a JSON document cut mid-structure no longer
     parses — so the tree below silently never appears for exactly the large
     payloads it exists to make readable. Saying so beats letting the view
     quietly degrade into a wall of text with no explanation.

     Derived rather than flagged by the server: `result_bytes` is the full
     byte length and `output` is the capped preview, so comparing them is
     exact. Both sides are byte counts, so multi-byte content cannot fake it
     the way comparing against a UTF-16 string length would. */
  var shownBytes = node.output ? new TextEncoder().encode(node.output).length : 0;
  var truncated = typeof node.result_bytes === "number" && node.result_bytes > shownBytes;
  if (truncated) {
    var note = document.createElement("p");
    note.className = "run-detail-note";
    note.textContent = "Showing the first " + shownBytes + " of " + node.result_bytes +
      " bytes — the rest was not recorded, so this is raw text rather than a parsed tree.";
    el.runDetail.appendChild(note);
  }

  // A div, not a <pre>: the JSON-tree branch fills this with interactive
  // <details> elements, and <pre> implies preformatted text content, not a
  // widget tree. .run-detail-output already sets white-space: pre-wrap
  // itself, so nothing about the flat-text case depends on the tag.
  // Clickable trace refs inside the detail (file:line, run ids) jump to source / graph
  var traceBar = document.createElement("div");
  traceBar.style.display = "flex"; traceBar.style.gap = "var(--space-2)"; traceBar.style.flexWrap = "wrap"; traceBar.style.marginBottom = "var(--space-2)";
  var rawOut = node.output || "";
  var traceRe = /(?:^|\s)([a-zA-Z0-9_\-\.\/]+\.(?:zig|ts|js|py|rs|go|md):\d+(?::\d+)?)/g;
  var m, seen = {}, cnt = 0;
  while ((m = traceRe.exec(rawOut)) && cnt < 6) {
    var ref = m[1];
    if (seen[ref]) continue; seen[ref] = true; cnt++;
    (function(r){
      var b = document.createElement("button"); b.type = "button"; b.className = "secondary"; b.textContent = r; upgradePfButton(b); b.title = "Search for " + r;
      b.addEventListener("click", function(){
        // cross-link to graph search and file search where available
        var s = document.querySelector("#run-filter"); if (s) { s.value = r.split(":")[0]; s.dispatchEvent(new Event("input",{bubbles:true})); }
        var gf = document.querySelector(".run-graph-search input");
        if (gf) { gf.value = r.split(":")[0].split("/").pop().split(".")[0]; gf.dispatchEvent(new Event("input",{bubbles:true})); }
      });
      traceBar.appendChild(b);
    })(ref);
  }
  if (traceBar.childNodes.length) el.runDetail.appendChild(traceBar);
  var subRe = /\[subagent run:\s*(sub-\d+)\]/g, sm;
  while ((sm = subRe.exec(rawOut)) !== null) {
    var sid = sm[1];
    var sb = document.createElement("button"); sb.type = "button"; sb.className = "secondary"; sb.textContent = "↗ " + sid; upgradePfButton(sb);
    sb.title = "Open sub-run " + sid;
    (function(id){ sb.addEventListener("click", function(){ if(typeof openRun==="function") openRun(id); }); })(sid);
    traceBar.appendChild(sb);
    if (!traceBar.parentNode) el.runDetail.appendChild(traceBar);
  }

  var out = document.createElement("div");
  out.className = "run-detail-output";
  /* A file-edit tool records its arguments (path/old/new or create/content)
     on the run node now, so the change itself renders here — the result
     line ("replaced 1 match") says it happened, not what it was. Old runs
     predate the field and fall through to the output below. */
  (function () {
    var argsStr = node.arguments || "";
    if (!argsStr) return;
    var argsParsed = null;
    try { argsParsed = JSON.parse(argsStr); } catch (e) { argsParsed = null; }
    // Truncated previews are invalid JSON on purpose (the cap cuts mid-string)
    // so a broken diff can never render: say so instead.
    if (!argsParsed) {
      if (argsStr.length >= 8000) {
        var truncNote = document.createElement("p");
        truncNote.className = "meta run-diff-truncated";
        truncNote.textContent = "arguments preview truncated — open the run's source to see the full change";
        out.appendChild(truncNote);
      }
      return;
    }
    var file = argsParsed.path;
    if (typeof file !== "string" || !file) return;
    var rows = [];
    var isCreate = argsParsed.create === true;
    if (isCreate && typeof argsParsed.content === "string") {
      var contentLines = argsParsed.content.replace(/\n$/, "").split("\n");
      contentLines.forEach(function (l) { rows.push({ kind: "add", text: l }); });
    } else if (typeof argsParsed.old === "string" && typeof argsParsed.new === "string") {
      rows = diffRows(argsParsed.old, argsParsed.new);
    } else {
      return;
    }
    var adds = rows.filter(function (r) { return r.kind === "add"; }).length;
    var dels = rows.filter(function (r) { return r.kind === "del"; }).length;
    var diffWrap = document.createElement("div");
    diffWrap.className = "diff-view edit-diff";
    var diffHead = document.createElement("div");
    diffHead.className = "diff-header";
    var fileTag = document.createElement("span");
    fileTag.textContent = "\u270e " + file;
    diffHead.appendChild(fileTag);
    var counts = document.createElement("span");
    counts.className = "diff-counts";
    counts.textContent = "+" + adds + " \u2212" + dels;
    diffHead.appendChild(counts);
    diffWrap.appendChild(diffHead);
    rows.forEach(function (r) {
      var row = document.createElement("div");
      row.className = "diff-line";
      row.setAttribute("data-kind", r.kind);
      var sign = document.createElement("span");
      sign.className = "diff-sign";
      sign.textContent = r.kind === "add" ? "+" : (r.kind === "del" ? "\u2212" : " ");
      row.appendChild(sign);
      var txt = document.createElement("span");
      txt.textContent = r.text;
      row.appendChild(txt);
      diffWrap.appendChild(row);
    });
    out.appendChild(diffWrap);
  })();
  if (node.output) {
    var parsed;
    if (!truncated) {
      try { parsed = JSON.parse(node.output); } catch (e) { parsed = undefined; }
    }
    // Unified diff heuristic: has hunk headers + +/- lines — render as Codex-style diff instead of plain text
    var looksDiff = !truncated && typeof node.output === "string" && /^@@ /m.test(node.output) && /(^\+[^+]|\n\+[^+]|^-[^-]|\n-[^-])/m.test(node.output);
    if (looksDiff) {
      var diffWrap = document.createElement("div"); diffWrap.className = "diff-view";
      var diffHead = document.createElement("div"); diffHead.className = "diff-header"; diffHead.textContent = "Patch"; diffWrap.appendChild(diffHead);
      node.output.split("\n").forEach(function(line){
        var row = document.createElement("div"); row.className = "diff-line";
        var sign = document.createElement("span"); sign.className = "diff-sign";
        if (line.indexOf("@@")===0) { row.setAttribute("data-kind","hunk"); sign.textContent = "●"; }
        else if (line.charAt(0)==="+") { row.setAttribute("data-kind","add"); sign.textContent = "+"; }
        else if (line.charAt(0)==="-") { row.setAttribute("data-kind","del"); sign.textContent = "−"; }
        else sign.textContent = " ";
        row.appendChild(sign);
        var txt = document.createElement("span"); txt.textContent = line; txt.style.flex="1"; txt.style.minWidth="0";
        row.appendChild(txt); diffWrap.appendChild(row);
      });
      out.appendChild(diffWrap);
    } else if (parsed !== undefined && typeof parsed === "object" && parsed !== null) {
      var tree = document.createElement("div");
      tree.className = "json-tree";
      tree.appendChild(buildJsonTree(parsed, null, 0));
      var treeBar = document.createElement("div");
      treeBar.style.display = "flex"; treeBar.style.gap = "var(--space-2)"; treeBar.style.marginBottom = "var(--space-2)";
      var expandAll = document.createElement("button"); expandAll.type="button"; expandAll.className="secondary"; expandAll.textContent="Expand all"; upgradePfButton(expandAll);
      expandAll.addEventListener("click", function(){ tree.querySelectorAll("details").forEach(function(d){ d.open=true; }); });
      var collapseAll = document.createElement("button"); collapseAll.type="button"; collapseAll.className="secondary"; collapseAll.textContent="Collapse all"; upgradePfButton(collapseAll);
      collapseAll.addEventListener("click", function(){ tree.querySelectorAll("details").forEach(function(d){ d.open=false; }); var first = tree.querySelector("details"); if(first) first.open = true; });
      treeBar.appendChild(expandAll); treeBar.appendChild(collapseAll);
      out.appendChild(treeBar); out.appendChild(tree);
    } else {
      var outCode = document.createElement("code");
      highlightInto(outCode, null, node.output);
      out.appendChild(outCode);
    }
  }
  el.runDetail.appendChild(out);

  el.runDetail.style.maxHeight = "42vh";
  el.runDetail.style.overflow = "auto";
  scrollTo(el.runDetail, "nearest");
  closeBtn.focus();
}

/* Hides the panel and clears the graph's selection. Shared by the Close
   button and by anything that removes the run the panel is describing. */
function closeNodeDetail() {
  el.runDetail.hidden = true;
  el.runDetail.textContent = "";
  el.runGraph.querySelectorAll(".run-node.selected").forEach(function (n) { n.classList.remove("selected"); });
}


/* The listeners below need `el`, so they bind on the view's first open
   (`bindOnce("runs", ...)` in app.js) rather than at module evaluation. */
export function bindRuns() {
  el.runSelect.addEventListener("change", function () {
    loadRun(el.runSelect.value);
  });
  
  var runFilterTimer = null;
  el.runFilter.addEventListener("input", function () {
    if (runFilterTimer) window.clearTimeout(runFilterTimer);
    runFilterTimer = window.setTimeout(function () {
      var wanted = renderRunOptions(el.runFilter.value);
      // Narrowing a filter usually leaves the same run on top. Refetching and
      // relaying out the graph it is already showing costs a round trip and a
      // full remeasure of every node box for no visible change.
      if (wanted && (!lastGraph || lastGraph.run_id !== wanted)) loadRun(wanted);
    }, 120);
  });
  
  el.runsRefresh.addEventListener("click", function () {
    el.runsRefresh.disabled = true;
    loadRuns().finally(function () { el.runsRefresh.disabled = false; });
  });
  (function(){
    var go=document.getElementById("run-compare-go"), clr=document.getElementById("run-compare-clear");
    if(!go) return;
    go.addEventListener("click", function(){
      var a=document.getElementById("run-compare-a"), b=document.getElementById("run-compare-b");
      if(a&&b) diffRuns(a.value, b.value);
    });
    if(clr) clr.addEventListener("click", function(){
      var s=document.getElementById("run-compare-status"); if(s) s.textContent="";
      clr.hidden=true; el.runDetail.textContent=""; el.runDetail.hidden=true;
      if(lastGraph) drawRun(lastGraph);
    });
  })();
  
}

/* app.js keeps thin forwarders over these: the command palette indexes the
   run list, the Copy-summary button needs the last built graph, deep links
   open a run by id, and the live-run tick draws a synthetic graph. */
export { loadRuns, openRun, drawRun, graphSummaryText, allRunsHolder };
export function lastBuiltGraph() { return lastBuilt; }
export function setPendingRunId(id) { pendingRunId = id; }
