// Vanilla, no bundler. Command palette — entries + rendering + keyboard.
import { fuzzyMatch as utilFuzzyMatch, view_digit_max } from "./utils.js";
import { openOverlay as overlayOpen, closeOverlay as overlayClose, trapOverlayTab as overlayTrapTab } from "./overlay.js";

var _VIEWS = null;
var _showView = null;
var _el = null;
var _refs = null;
var _setRailOpen = null;
var _switchSession = null;
var _openRun = null;
var _renderBoard = null;
var _showToolDetail = null;
var _setOpenCardId = null;

var paletteItems = [];
var paletteIndex = 0;

export function paletteEntries() {
  var out = [];
  _VIEWS.forEach(function (v, i) {
    // The number is a promise that a key does this, so it is only printed for
    // the views a key can actually reach. Past the ninth it read "(10)" …
    // "(14)" — a shortcut nobody can type, on the one surface whose job is to
    // teach the shortcuts.
    var digit = i < view_digit_max ? "  (" + (i + 1) + ")" : "";
    out.push({ kind: "view", label: v.charAt(0).toUpperCase() + v.slice(1) + digit, run: function () { _showView(v, true); } });
  });
  out.push({ kind: "action", label: "New chat", run: function () { _el.newChat.click(); } });
  out.push({ kind: "action", label: "New workspace", run: function () {
    if (_el.workspaceNew) _el.workspaceNew.click();
  } });
  out.push({ kind: "action", label: "Fork this conversation", run: function () { _el.sessionFork.click(); } });
  out.push({ kind: "action", label: "Compact this conversation", run: function () { _el.sessionCompact.click(); } });
  out.push({ kind: "action", label: "Export this conversation as Markdown", run: function () { _el.sessionExport.click(); } });
  out.push({ kind: "action", label: "Choose theme", run: function () { _el.themeToggle.click(); } });
  out.push({ kind: "action", label: "Keyboard shortcuts", run: function () { overlayOpen(_el.help, _el.helpClose); } });
  _refs.knownSessionsHolder.list.forEach(function (s) {
    out.push({ kind: "chat", label: _refs.sessionLabel(s), run: function () { _showView("chat", false); _switchSession(s.id); } });
  });
  _refs.allRunsHolder.list.forEach(function (r) {
    var taskPart = r.task ? " " + r.task.slice(0, 80) : "";
    out.push({ kind: "run", label: _refs.runLabel(r) + taskPart, run: function () { _openRun(r.run_id); } });
    // Also index node labels so palette search can hit inside a run
    if (r.nodes && r.nodes.length) {
      for (var ni=0; ni<Math.min(r.nodes.length, 6); ni++) {
        (function(rr, nd){ var lbl = nd.label || nd.detail || ""; if(!lbl) return; out.push({ kind: "node", label: lbl.slice(0,64) + " · " + rr.run_id.slice(0,8), run: function(){ _openRun(rr.run_id); } }); })(r, r.nodes[ni]);
      }
    }
  });
  _refs.board.cards.forEach(function (c) {
    out.push({ kind: "card", label: c.title + "  ·  " + c.column, run: function () {
      if (_setOpenCardId) _setOpenCardId(c.id);
      _showView("kanban", true);
      _renderBoard(_refs.board);
    } });
  });
  (_refs.goalState.val || []).forEach(function (g) {
    var label = (g.objective || g.id || "goal").slice(0, 96);
    var st = g.status ? " · " + g.status : "";
    out.push({ kind: "goal", label: label + st, run: function () { _showView("goals", true); } });
  });
  _refs.allToolsHolder.list.forEach(function (t2) {
    var label = t2.name + (t2.description ? "  ·  " + t2.description.slice(0, 80) : "");
    out.push({ kind: "tool", label: label, run: function () { _showView("tools", true); _showToolDetail(t2); } });
  });
  return out;
}

function renderPalette() {
  var rawQ = _el.paletteInput.value.trim();
  var q = rawQ.toLowerCase();
  var empty = !q;
  var all = paletteEntries();
  paletteItems = [];
  _el.paletteList.textContent = "";
  for (var i = 0; i < all.length && paletteItems.length < 40; i++) {
    if (!empty && !utilFuzzyMatch(q, all[i].kind + " " + all[i].label)) continue;
    paletteItems.push(all[i]);
  }
  if (paletteIndex >= paletteItems.length) paletteIndex = 0;
  paletteItems.forEach(function (entry, i) {
    var li = document.createElement("li");
    li.className = "palette-item";
    li.id = "palette-item-" + i;
    li.setAttribute("role", "option");
    li.setAttribute("aria-selected", String(i === paletteIndex));
    var kind = document.createElement("span");
    kind.className = "palette-kind";
    kind.textContent = entry.kind;
    var label = document.createElement("span");
    label.className = "palette-label";
    label.textContent = entry.label;
    label.title = entry.label;
    li.appendChild(kind);
    li.appendChild(label);
    li.addEventListener("click", function () { runPalette(i); });
    _el.paletteList.appendChild(li);
  });
  if (!paletteItems.length) {
    var empty2 = document.createElement("li");
    empty2.className = "palette-item";
    empty2.textContent = "Nothing matches.";
    _el.paletteList.appendChild(empty2);
  }
  _el.paletteInput.setAttribute("aria-activedescendant", paletteItems.length ? "palette-item-" + paletteIndex : "");
}

function runPalette(i) {
  var entry = paletteItems[i];
  overlayClose(_el.palette);
  if (entry) entry.run();
}

export function openPalette() {
  _el.paletteInput.value = "";
  paletteIndex = 0;
  overlayOpen(_el.palette, _el.paletteInput);
  renderPalette();
}

function bindPaletteEvents() {
  _el.paletteOpen.addEventListener("click", openPalette);
  _el.paletteInput.addEventListener("input", function () { paletteIndex = 0; renderPalette(); });
  _el.paletteInput.addEventListener("keydown", function (e) {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (!paletteItems.length) return;
      var step = e.key === "ArrowDown" ? 1 : -1;
      paletteIndex = (paletteIndex + step + paletteItems.length) % paletteItems.length;
      renderPalette();
      var sel = document.getElementById("palette-item-" + paletteIndex);
      if (sel && sel.scrollIntoView) sel.scrollIntoView({ block: "nearest" });
      return;
    }
    if (e.key === "Enter") {
      e.preventDefault();
      runPalette(paletteIndex);
    }
  });
  [_el.palette, _el.help].forEach(function (node) {
    node.addEventListener("mousedown", function (e) {
      if (e.target === node) overlayClose(node);
    });
  });
}

export function bindPalette(ctx) {
  _VIEWS = ctx.VIEWS;
  _showView = ctx.showView;
  _el = ctx.el;
  _refs = ctx.refs;
  _setRailOpen = ctx.setRailOpen;
  _switchSession = ctx.switchSession;
  _openRun = ctx.openRun;
  _renderBoard = ctx.renderBoard;
  _showToolDetail = ctx.showToolDetail;
  _setOpenCardId = ctx.setOpenCardId;
  bindPaletteEvents();
}

export function paletteKeyHandler(e, ctx) {
  var rail = ctx.el ? ctx.el.rail : _el.rail;
  var textPromptEl = ctx.el ? ctx.el.textPrompt : _el.textPrompt;
  var finishTextPrompt = ctx.finishTextPrompt;
  if (e.key === "Tab") {
    if (_el.workspaceNewDialog && !_el.workspaceNewDialog.hidden) { overlayTrapTab(e, _el.workspaceNewDialog); return true; }
    if (!textPromptEl.hidden) { overlayTrapTab(e, textPromptEl); return true; }
    if (!_el.palette.hidden) { overlayTrapTab(e, _el.palette); return true; }
    if (!_el.help.hidden) { overlayTrapTab(e, _el.help); return true; }
    return false;
  }
  if (e.key === "Escape") {
    if (_el.workspaceNewDialog && !_el.workspaceNewDialog.hidden) { overlayClose(_el.workspaceNewDialog); e.preventDefault(); return true; }
    if (!textPromptEl.hidden) { finishTextPrompt(null); e.preventDefault(); return true; }
    if (!_el.palette.hidden) { overlayClose(_el.palette); e.preventDefault(); return true; }
    if (rail.getAttribute("data-open") === "true") { ctx.setRailOpen(false); ctx.el.railToggle.focus(); e.preventDefault(); return true; }
    if (!_el.help.hidden) { overlayClose(_el.help); e.preventDefault(); return true; }
    return false;
  }
  if ((e.ctrlKey || e.metaKey) && (e.key === "k" || e.key === "K")) {
    e.preventDefault();
    if (_el.palette.hidden) openPalette(); else overlayClose(_el.palette);
    return true;
  }
  if (e.key === "?" && !e.ctrlKey && !e.metaKey && !e.altKey) {
    var t = e.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return false;
    e.preventDefault();
    overlayOpen(_el.help, _el.helpClose);
    return true;
  }
  return false;
}
