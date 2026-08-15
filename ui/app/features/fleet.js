// Fleet / cross-agent view — ES module, no bundler.
// Owns #view-fleet: roster + DM channels + grouped runs. Works without app.js.
import { clip, peerColor, escapeHtml, themeToken, cssColorAlpha, cssColorMix } from "../core/utils.js";
import { readJson } from "../core/vendor.js";
import { onLive, liveOk } from "../core/stream.js";

var _navShowView = null;
export function setNavShowView(fn) { _navShowView = typeof fn === "function" ? fn : null; }
var _openRun = null;
export function setOpenRun(fn) { _openRun = typeof fn === "function" ? fn : null; }

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

function renderRoster(container, status, a2a, cards) {
  container.textContent = "";
  container.className = "fleet-roster";
  if (!status || !status.instance) {
    container.appendChild(el("p", "run-empty", "No status yet."));
    // still render self card if available even when status missing
    if (a2a) renderA2ACard(container, a2a);
    return;
  }
  var inst = status.instance;
  var head = el("p", "fleet-meta");
  head.textContent = inst.name + " (" + inst.id.slice(0, 8) + ")";
  container.appendChild(head);
  // /api/peers scans each peer's A2A card server-side; merge by peer name so
  // a roster entry can say who a peer is, not just where it listens.
  var byName = Object.create(null);
  if (cards && cards.ok && Array.isArray(cards.peers)) {
    cards.peers.forEach(function (c) { if (c && c.name) byName[c.name] = c; });
  }
  var peers = status.peers || [];
  if (!peers.length) {
    var empty = el("p", "run-empty", "No peers configured. Add a peer in System → Config to see its status and skills here. ");
    var go = el("button", "primary", "Open Config");
    go.type = "button";
    go.addEventListener("click", navToSystemConfig);
    empty.appendChild(go);
    container.appendChild(empty);
  } else {
    var ul = el("ul", "fleet-roster-list");
    ul.setAttribute("role", "list");
    peers.forEach(function (p) {
      var li = el("li", "fleet-meta");
      li.setAttribute("role", "listitem");
      var c = byName[p.name];
      var label = p.name + " \u2014 " + p.url;
      if (c && c.status === "up") {
        li.textContent = label + " \u00b7 up";
        if (c.card_name && c.card_name !== p.name) li.textContent += " \u00b7 " + c.card_name;
        var extra = [];
        if (c.description) extra.push(c.description);
        if (Array.isArray(c.skills) && c.skills.length) extra.push("skills: " + c.skills.join(", "));
        li.title = extra.length ? extra.join("\n") : p.url;
      } else if (c && c.status === "down") {
        li.textContent = label + " \u00b7 down";
        li.title = c.error ? p.url + "\n" + c.error : p.url;
      } else {
        li.textContent = label;
        li.title = p.url;
      }
      ul.appendChild(li);
    });
    container.appendChild(ul);
  }
  if (a2a !== undefined) renderA2ACard(container, a2a);
}

function renderA2ACard(container, card) {
  var wrap = el("div", "fleet-a2a");
  wrap.setAttribute("role", "group");
  wrap.setAttribute("aria-label", "This agent");
  var head = el("div", "fleet-a2a-head", "This agent");
  wrap.appendChild(head);
  if (!card) {
    wrap.appendChild(el("p", "fleet-meta", "A2A card unavailable."));
    container.appendChild(wrap);
    return;
  }
  var name = card.name || card.displayName || card.id || "";
  var disp = card.displayName || card.id || "";
  if (name) wrap.appendChild(el("div", "fleet-a2a-name", name));
  if (disp && disp !== name) wrap.appendChild(el("div", "fleet-a2a-id", disp));
  else if (card.id) wrap.appendChild(el("div", "fleet-a2a-id", String(card.id).slice(0, 32)));
  var skills = card.skills || card.capabilities;
  var summary = "";
  if (Array.isArray(skills)) summary = skills.join(", ");
  else if (skills && typeof skills === "object") {
    var keys = Object.keys(skills);
    summary = keys.length ? keys.join(", ") : "";
  } else if (typeof skills === "string") summary = skills;
  if (summary) wrap.appendChild(el("div", "fleet-a2a-skills", summary));
  else wrap.appendChild(el("div", "fleet-meta", "A2A card available"));
  container.appendChild(wrap);
}

function navToSystemConfig() {
  try {
    if (_navShowView) _navShowView("system");
    else if (typeof window.showView === "function") window.showView("system");
    else if (window.clankerApp && typeof window.clankerApp.showView === "function") window.clankerApp.showView("system");
    else window.location.hash = "#system";
  } catch (_) { window.location.hash = "#system"; }
  var target = document.getElementById("config-editor-section");
  if (!target || !target.scrollIntoView) return;
  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  try { target.scrollIntoView({ block: "start", behavior: reduced ? "auto" : "smooth" }); } catch (_) {}
}
function isDmRoom(room) { return typeof room === "string" && room.indexOf("dm:") === 0; }
function dmNames(room) { return isDmRoom(room) ? room.slice(3).split("|").join(" \u2194 ") : room; }
function navToChat() {
  try {
    if (_navShowView) _navShowView("chat");
    else if (typeof window.showView === "function") window.showView("chat");
    else if (window.clankerApp && typeof window.clankerApp.showView === "function") window.clankerApp.showView("chat");
    else window.location.hash = "#chat";
  } catch (_) { window.location.hash = "#chat"; }
}
function navToRooms(room) {
  try {
    if (_navShowView) _navShowView("rooms");
    else if (typeof window.showView === "function") window.showView("rooms");
    else if (window.clankerApp && typeof window.clankerApp.showView === "function") window.clankerApp.showView("rooms");
    else window.location.hash = "#rooms";
  } catch (_) { window.location.hash = "#rooms"; }
  if (!room) return;
  var sel = document.getElementById("chat-room");
  if (!sel) return;
  try {
    for (var i = 0; i < sel.options.length; i++) if (sel.options[i].value === room) {
      sel.value = room; sel.dispatchEvent(new Event("change", { bubbles: true })); break;
    }
  } catch (_) {}
}
function normalizeChatData(d) {
  if (d == null) return null;
  if (Array.isArray(d)) return { rooms: d, subscribed: [] };
  if (typeof d === "object") {
    var rooms = d.rooms; if (!Array.isArray(rooms) && Array.isArray(d.data)) rooms = d.data;
    if (!Array.isArray(rooms)) rooms = [];
    var subs = d.subscribed || d.subscriptions || d.subs || [];
    if (!Array.isArray(subs)) subs = [];
    return { rooms: rooms, subscribed: subs };
  }
  return { rooms: [], subscribed: [] };
}

function renderDMs(container, chatData) {
  if (!container) return;
  container.textContent = "";
  container.className = "fleet-dms";
  if (chatData === null) {
    container.appendChild(el("p", "run-empty", "DMs unavailable. Enable the chat module to message peers from Fleet."));
    return;
  }
  var norm = normalizeChatData(chatData);
  if (!norm) {
    container.appendChild(el("p", "run-empty", "No DM data."));
    return;
  }
  var rooms = norm.rooms || [];
  var subs = norm.subscribed || [];
  var dmRooms = rooms.filter(function (r) { return isDmRoom(r.room); });
  if (!dmRooms.length) {
    var empty = el("p", "run-empty", "No DM channels yet. Open a peer in Rooms and send the first message. ");
    var goRooms = el("button", "primary", "Open Rooms");
    goRooms.type = "button";
    goRooms.addEventListener("click", function () { navToRooms(); });
    empty.appendChild(goRooms);
    container.appendChild(empty);
    if (rooms.length && !dmRooms.length) {
      var hint = el("p", "fleet-meta", rooms.length + " room(s), none are DMs.");
      container.appendChild(hint);
    }
    return;
  }
  var subSet = {};
  subs.forEach(function (s) { subSet[s] = true; });
  var list = el("div", "fleet-dm-list");
  list.setAttribute("role", "list");
  dmRooms.forEach(function (r) {
    var card = el("div", "tool-row fleet-card fleet-dm-card");
    card.setAttribute("role", "listitem");
    var left = el("div", "fleet-card__main");
    var titleRow = el("div", "fleet-dm-title-row");
    var badge = el("span", "tool-tag fleet-dm-badge", "DM");
    badge.setAttribute("aria-hidden", "true");
    var title = el("span", "tool-name");
    title.textContent = dmNames(r.room);
    title.title = r.room;
    titleRow.appendChild(badge);
    titleRow.appendChild(title);
    var metaText = (r.messages != null ? r.messages + " msgs" : "");
    if (r.last_from) metaText += (metaText ? " \u00b7 " : "") + "last " + r.last_from;
    if (subSet[r.room]) metaText += (metaText ? " \u00b7 " : "") + "subscribed";
    var meta = el("div", "fleet-meta", metaText || r.room);
    if (r.last_text) {
      var preview = el("div", "fleet-meta fleet-dm-preview", clip(r.last_text, 100));
      preview.title = r.last_text;
      left.appendChild(titleRow);
      left.appendChild(meta);
      left.appendChild(preview);
    } else {
      left.appendChild(titleRow);
      left.appendChild(meta);
    }
    var actions = el("div", "fleet-actions toolbar-actions");
    var btn = el("button", "secondary", "Open");
    btn.type = "button";
    btn.setAttribute("aria-label", "Open DM " + dmNames(r.room));
    btn.addEventListener("click", function () { navToRooms(r.room); });
    actions.appendChild(btn);
    card.addEventListener("click", function (e) {
      if (e.target.closest && e.target.closest("button")) return;
      navToRooms(r.room);
    });
    card.appendChild(left);
    card.appendChild(actions);
    list.appendChild(card);
  });
  container.appendChild(list);
}

function renderRuns(container, detailNode, runs) {
  container.textContent = "";
  if (!runs.length) {
    var empty = el("p", "run-empty", "No runs recorded yet. Start a task in Chat to watch its agent tree here. ");
    var goChat = el("button", "primary", "Open Chat");
    goChat.type = "button";
    goChat.addEventListener("click", navToChat);
    empty.appendChild(goChat);
    container.appendChild(empty);
    return;
  }
  var grouped = groupRuns(runs);

  function openRun(id) {
    if (_openRun) { try { _openRun(id); return; } catch (_) {} }
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

  container.setAttribute("role", "list");
  grouped.roots.forEach(function (root) {
    var children = grouped.childrenOf[root.run_id] || [];
    var hasKids = !!children.length;
    var card = el("div", "tool-row fleet-card " + (hasKids ? "fleet-card--parent" : "fleet-card--plain"));
    card.setAttribute("role", "listitem");
    card.addEventListener("click", function (e) {
      if (e.target.closest && e.target.closest("button")) return;
      openRun(root.run_id);
    });
    var left = el("div", "fleet-card__main");
    var title = el("div", "tool-name", clip(root.task || root.run_id, 120));
    title.title = root.task || root.run_id;
    var meta = el("div", "fleet-meta", root.run_id + " \u00b7 " + fmtRunMeta(root));
    left.appendChild(title);
    left.appendChild(meta);
    if (hasKids) {
      var subMeta = el("div", "fleet-meta", children.length + " sub-run" + (children.length > 1 ? "s" : ""));
      left.appendChild(subMeta);
    }
    var actions = el("div", "fleet-actions toolbar-actions");
    var btn = el("button", "secondary", "Open");
    btn.type = "button";
    btn.setAttribute("aria-label", "Open run " + root.run_id);
    btn.addEventListener("click", function () { openRun(root.run_id); });
    actions.appendChild(btn);
    if (hasKids) {
      var toggle = el("button", "secondary fleet-toggle", hasKids ? "Hide" : "Show");
      toggle.type = "button";
      toggle.setAttribute("aria-expanded", "true");
      toggle.setAttribute("aria-label", "Toggle sub-runs for " + root.run_id);
      actions.appendChild(toggle);
    }
    card._open = openRun;
    card.appendChild(left);
    card.appendChild(actions);
    container.appendChild(card);

    var sub = null;
    if (children.length) {
      sub = el("div", "fleet-children fleet-child-group");
      sub.setAttribute("role", "list");
      children.forEach(function (child) {
        var row = el("div", "tool-row fleet-card fleet-child");
        row.setAttribute("role", "listitem");
        row.addEventListener("click", function (e) {
          if (e.target.closest && e.target.closest("button")) return;
          openRun(child.run_id);
        });
        var l2 = el("div", "fleet-child__main");
        l2.appendChild(el("div", "tool-name", child.run_id));
        l2.appendChild(el("div", "fleet-meta", clip(child.task || "", 100) + (child.task ? " \u00b7 " : "") + fmtRunMeta(child)));
        var a2 = el("div", "fleet-actions toolbar-actions");
        var b2 = el("button", "secondary", "Open");
        b2.type = "button";
        b2.setAttribute("aria-label", "Open run " + child.run_id);
        b2.addEventListener("click", function () { openRun(child.run_id); });
        a2.appendChild(b2);
        row.appendChild(l2);
        row.appendChild(a2);
        sub.appendChild(row);
      });
      container.appendChild(sub);
      var tBtn = actions.querySelector(".fleet-toggle");
      if (tBtn) {
        tBtn.addEventListener("click", function (e) {
          e.stopPropagation();
          var isHidden = sub.hidden;
          sub.hidden = !isHidden;
          tBtn.textContent = isHidden ? "Hide" : "Show";
          tBtn.setAttribute("aria-expanded", isHidden ? "true" : "false");
          card.classList.toggle("fleet-card--collapsed", !isHidden);
        });
      }
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
          row2.addEventListener("click", function (e) {
            if (e.target.closest && e.target.closest("button")) return;
            openRun(sid);
          });
          row2.appendChild(el("div", "tool-name", sid));
          var a = el("div", "toolbar-actions");
          var b = el("button", "secondary", "Open");
          b.type = "button";
          b.setAttribute("aria-label", "Open run " + sid);
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

var _floorRAF = null;
var _floorState = { runs: [], names: ["self"], t: 0, phase: {}, idle: {} };
function _toolBucket(label){
  var l=(label||"").toLowerCase();
  if(l.indexOf("read")!==-1||l.indexOf("grep")!==-1||l.indexOf("glob")!==-1) return "read";
  if(l.indexOf("edit")!==-1||l.indexOf("write")!==-1||l.indexOf("patch")!==-1) return "edit";
  if(l.indexOf("exec")!==-1||l.indexOf("git")!==-1||l.indexOf("zig")!==-1||l.indexOf("test")!==-1) return "exec";
  if(l.indexOf("subagent")!==-1||l.indexOf("rlm")!==-1) return "sub";
  if(l.indexOf("ask")!==-1) return "ask";
  return "tool";
}

// The canvas palette is seeded from the active theme's computed tokens each
// frame, never a fixed dark ramp, so a light data-theme paints a light floor
// and the status hues follow --ok/--warn/--accent and stay re-tunable. Frames
// re-read the tokens on every draw; reduced-motion static frames are re-seeded
// by the theme observer registered in initFleet.
function _floorTheme() {
  return {
    bg: themeToken("--surface-2"),
    surface: themeToken("--surface"),
    border: themeToken("--border"),
    fg: themeToken("--fg"),
    muted: themeToken("--fg-muted"),
    paper: themeToken("--paper"),
    accent: themeToken("--accent"),
    ok: themeToken("--ok"),
    warn: themeToken("--warn"),
    okFill: themeToken("--ok-fill")
  };
}
function _floorFrame(ts){
  var cv=byId("fleet-canvas"); var lab=byId("fleet-floor-status");
  if(!cv || cv.closest && cv.closest("#fleet-floor[hidden]") || !document.body.contains(cv)) { _floorRAF=null; return; }
  var view=byId("view-fleet");
  if(view && view.hidden) { _floorRAF=null; return; }
  var ctx=cv.getContext("2d"); if(!ctx){ if(lab) lab.textContent="Canvas unavailable."; return; }
  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var t = reduced ? _floorState.t : (ts||0);
  var pal = _floorTheme();
  ctx.imageSmoothingEnabled=false;
  ctx.clearRect(0,0,cv.width,cv.height);
  ctx.fillStyle=pal.bg; ctx.fillRect(0,0,cv.width,cv.height);
  // brushed backplane lines
  ctx.fillStyle=cssColorAlpha(pal.fg, 0.04);
  for(var gx=0; gx<cv.width; gx+=8) ctx.fillRect(gx, 0, 1, cv.height);
  var names=_floorState.names; var cols=Math.max(1,names.length); var cw=cv.width/cols;
  for(var i=0;i<names.length;i++){
    var x=Math.floor(i*cw);
    var name=names[i];
    var bucket=_floorState.phase[name] || "idle";
    var idleFor = Date.now() - (_floorState.idle[name]||Date.now());
    var dozing = idleFor > 5*60*1000;
    var glow = dozing ? pal.muted : (bucket==="ask" ? pal.accent : bucket==="tool" ? pal.ok : bucket==="exec" ? pal.warn : pal.ok);
    var breathe = reduced || dozing ? 1 : 0.75 + 0.25*Math.sin(t/900 + i);
    // floor tile + desk, toned from the active theme rather than a dark ramp
    ctx.fillStyle=pal.border; ctx.fillRect(x+6, 110, Math.floor(cw)-12, 40);
    ctx.fillStyle=pal.surface; ctx.fillRect(x+12, 86, Math.floor(cw)-24, 10);
    ctx.fillStyle=pal.border; ctx.fillRect(x+10, 96, Math.floor(cw)-20, 14);
    // agent body (simple pill)
    var bob = reduced||dozing ? 0 : Math.sin(t/420 + i*1.1)*2;
    ctx.fillStyle=peerColor(name);
    var bx=x+Math.floor(cw/2)-10, by=62+bob;
    // head
    ctx.fillRect(bx+6, by-8, 8, 8);
    // torso
    ctx.fillRect(bx+2, by, 16, 18);
    // arms by bucket
    if(bucket==="read") { ctx.fillRect(bx-4, by+4, 6, 3); ctx.fillRect(bx+18, by+4, 6, 3); }
    else if(bucket==="exec"||bucket==="tool") { ctx.fillRect(bx+4, by+4, 10, 3); }
    else if(bucket==="edit") { ctx.fillRect(bx+6, by+6, 8, 2); }
    // lamp
    ctx.globalAlpha=breathe; ctx.fillStyle=glow; ctx.beginPath(); ctx.arc(x+Math.floor(cw/2), 48, 6, 0, Math.PI*2); ctx.fill(); ctx.globalAlpha=1;
    if(dozing){ ctx.fillStyle=cssColorAlpha(pal.fg, 0.9); ctx.font="9px monospace"; ctx.textAlign="center"; ctx.fillText("zZ", x+Math.floor(cw/2), 44); }
    // label
    ctx.fillStyle=pal.muted; ctx.font="10px monospace"; ctx.textAlign="center"; ctx.fillText(name.slice(0,12), x+Math.floor(cw/2), 168);
    // helper sprite
    if(bucket==="sub"){ ctx.fillStyle=pal.okFill; ctx.fillRect(x+Math.floor(cw/2)+12, by+6, 6, 10); }
  }
  if(lab){
    if(reduced) lab.textContent="Fleet floor — still frame ("+names.length+" desks). Respecting reduced motion.";
    else lab.textContent=names.length+" desk(s) · animated by tool events; roster and runs below are source of truth.";
  }
  if(!reduced) _floorRAF=requestAnimationFrame(_floorFrame);
  else _floorRAF=null;
}
function renderFloor(runs, roster){
  var floor=byId("fleet-floor"); var cv=byId("fleet-canvas"); var lab=byId("fleet-floor-status");
  if(!floor || !cv) return;
  floor.hidden=false;
  var peers=(roster && roster.peers)||[];
  _floorState.names=["self"].concat(peers.map(function(p){return p.name;}));
  // seed phases from recent tool activity in runs (best-effort: last tool label per parent)
  _floorState.runs=runs||[];
  var now=Date.now();
  // map run provider/model activity to bucket by last seen tool kind
  // (no run-stream here yet, so seed from available metadata; live SSE below keeps it current)
  (runs||[]).forEach(function(r){
    var n=(r.task||"")+" "+(r.provider||"");
    var b=_toolBucket(n);
    var target = r.parent_run_id ? "self" : (_floorState.names[1]||"self");
    _floorState.phase[target]=b; _floorState.idle[target]=now;
  });
  // ensure every desk has an idle stamp
  _floorState.names.forEach(function(n){ if(!_floorState.idle[n]) _floorState.idle[n]=now; });
  if(_floorRAF) cancelAnimationFrame(_floorRAF);
  _floorRAF=requestAnimationFrame(_floorFrame);
  // live tick from /api/run stream is attached by fleet live listener below
}

var _meshTimer = null;
var _meshTopo = "";

function meshPos(nodes, i, w, h) {
  if (i === 0) return { x: w / 2, y: h / 2 };
  var n = Math.max(nodes.length - 1, 1);
  var a = (-Math.PI / 2) + ((i - 1) * 2 * Math.PI / n);
  return { x: w / 2 + Math.cos(a) * w * 0.32, y: h / 2 + Math.sin(a) * h * 0.34 };
}

function meshTopoKey(data) {
  var nodes = (data.nodes || []).map(function (n) { return n.id + "|" + (n.name || "") + "|" + (n.state || ""); }).join(";");
  var links = (data.links || []).map(function (l) { return l.from + ">" + l.to; }).join(";");
  var pulses = (data.pulses || []).map(function (p) { return p.from + ">" + p.to; }).sort().join(";");
  return themeToken("--accent") + "#" + themeToken("--bg") + "#" + nodes + "#" + links + "#" + pulses;
}

function meshStatusText(data) {
  var nodes = data.nodes || [];
  var links = data.links || [];
  var pulses = data.pulses || [];
  var working = nodes.filter(function (n) { return n.working; }).length;
  if (nodes.length <= 1 && !links.length) {
    return "This clanker only. Add a peer in System → Config to see others on the map.";
  }
  return nodes.length + " node" + (nodes.length === 1 ? "" : "s") +
    (links.length ? ", " + links.length + " link" + (links.length === 1 ? "" : "s") : "") +
    (working ? ", " + working + " working" : "") +
    (pulses.length ? ", " + pulses.length + " talking" : "") +
    (data.mesh ? "" : ". Mesh module off; showing configured peers.");
}

function patchMeshWorking(el, data, statusEl) {
  var byId = Object.create(null);
  (data.nodes || []).forEach(function (n) { byId[n.id] = n; });
  var groups = el.querySelectorAll("[data-node]");
  for (var i = 0; i < groups.length; i++) {
    var g = groups[i];
    var n = byId[g.getAttribute("data-node")];
    var working = !!(n && n.working);
    g.classList.toggle("mesh-node--working", working);
    var meta = g.querySelector(".mesh-node-meta");
    if (meta && n) {
      meta.textContent = working ? "working" : (n.state === "self" ? "home" : (n.path || n.state));
    }
  }
  if (statusEl) statusEl.textContent = meshStatusText(data);
}

function renderMeshMap(el, data, statusEl) {
  if (!el) return;
  if (!data || data.ok === false) {
    _meshTopo = "";
    el.innerHTML = "";
    if (statusEl) statusEl.textContent = (data && data.error) || "Mesh map unavailable.";
    return;
  }
  var topo = meshTopoKey(data);
  if (topo === _meshTopo && el.querySelector("svg")) {
    patchMeshWorking(el, data, statusEl);
    return;
  }
  _meshTopo = topo;
  var nodes = data.nodes || [];
  var links = data.links || [];
  var pulses = data.pulses || [];
  var w = 800;
  var h = 420;
  var pos = {};
  nodes.forEach(function (n, i) { pos[n.id] = meshPos(nodes, i, w, h); });
  var parts = [];
  parts.push('<svg viewBox="0 0 ' + w + " " + h + '" role="presentation">');
  parts.push("<defs>");
  var paper = themeToken("--paper");
  var muted = themeToken("--fg-muted");
  var accent = themeToken("--accent");
  var ok = themeToken("--ok-fill") || themeToken("--ok");
  parts.push('<radialGradient id="mesh-lamp-idle" cx="35%" cy="30%"><stop offset="0%" stop-color="' + cssColorMix(muted, paper, 0.45) + '"/><stop offset="70%" stop-color="' + muted + '"/><stop offset="100%" stop-color="' + cssColorMix(muted, themeToken("--fg"), 0.35) + '"/></radialGradient>');
  parts.push('<radialGradient id="mesh-lamp-self" cx="35%" cy="30%"><stop offset="0%" stop-color="' + cssColorMix(accent, paper, 0.45) + '"/><stop offset="65%" stop-color="' + accent + '"/><stop offset="100%" stop-color="' + cssColorMix(accent, themeToken("--fg"), 0.4) + '"/></radialGradient>');
  parts.push('<radialGradient id="mesh-lamp-live" cx="35%" cy="30%"><stop offset="0%" stop-color="' + cssColorMix(ok, paper, 0.45) + '"/><stop offset="60%" stop-color="' + ok + '"/><stop offset="100%" stop-color="' + cssColorMix(ok, themeToken("--fg"), 0.4) + '"/></radialGradient>');
  parts.push("</defs>");
  links.forEach(function (l, i) {
    var a = pos[l.from];
    var b = pos[l.to];
    if (!a || !b) return;
    var pulse = null;
    pulses.forEach(function (p) {
      if ((p.from === l.from && p.to === l.to) || (p.from === l.to && p.to === l.from)) pulse = p;
    });
    var reverse = pulse && pulse.from === l.to;
    var id = "mesh-wire-" + i;
    parts.push('<path id="' + id + '" class="mesh-wire' + (pulse ? " mesh-wire--live" : "") +
      (reverse ? " mesh-wire--rev" : "") +
      '" d="M' + a.x.toFixed(1) + " " + a.y.toFixed(1) + " L" + b.x.toFixed(1) + " " + b.y.toFixed(1) + '"/>');
    if (!pulse) return;
    parts.push('<circle class="mesh-pulse" r="4.5"><animateMotion dur="1.6s" repeatCount="indefinite" rotate="auto" keyPoints="' +
      (reverse ? "1;0" : "0;1") + '" keyTimes="0;1" calcMode="linear"><mpath href="#' + id + '"/></animateMotion></circle>');
  });
  nodes.forEach(function (n) {
    var p = pos[n.id];
    if (!p) return;
    var r = n.state === "self" ? 22 : 16;
    var cls = "mesh-node" + (n.state === "self" ? " mesh-node--self" : "") + (n.working ? " mesh-node--working" : "");
    parts.push('<g class="' + cls + '" data-node="' + escapeHtml(n.id) + '">');
    parts.push('<circle class="mesh-node-halo" cx="' + p.x.toFixed(1) + '" cy="' + p.y.toFixed(1) + '" r="' + (r * 1.75).toFixed(1) + '"/>');
    parts.push('<circle class="mesh-node-lamp" cx="' + p.x.toFixed(1) + '" cy="' + p.y.toFixed(1) + '" r="' + r + '"/>');
    parts.push('<text class="mesh-node-label" x="' + p.x.toFixed(1) + '" y="' + (p.y + r + 16).toFixed(1) + '">' + escapeHtml(n.name || n.id) + "</text>");
    parts.push('<text class="mesh-node-meta" x="' + p.x.toFixed(1) + '" y="' + (p.y + r + 28).toFixed(1) + '">' +
      escapeHtml(n.working ? "working" : (n.state === "self" ? "home" : (n.path || n.state))) + "</text>");
    parts.push("</g>");
  });
  parts.push("</svg>");
  el.innerHTML = parts.join("");
  if (statusEl) statusEl.textContent = meshStatusText(data);
}

function observeFloorTheme() {
  var root = document.documentElement;
  if (!root || typeof MutationObserver === "undefined") return;
  new MutationObserver(function () {
    var cv = byId("fleet-canvas");
    if (!cv || !document.body.contains(cv)) return;
    // Re-seed so a static reduced-motion frame (or the running loop) picks up
    // the new palette, without stacking a second animation loop.
    if (_floorRAF) cancelAnimationFrame(_floorRAF);
    _floorRAF = requestAnimationFrame(_floorFrame);
  }).observe(root, { attributes: true, attributeFilter: ["data-theme"] });
}

export function initFleet() {
  var view = byId("view-fleet");
  if (!view) return;
  var roster = byId("fleet-roster");
  var runsEl = byId("fleet-runs");
  var dmsEl = byId("fleet-dms");
  var detail = byId("fleet-detail");
  var statusEl = byId("fleet-status");
  var refresh = byId("fleet-refresh");
  var mapEl = byId("mesh-map");
  var mapStatus = byId("mesh-map-status");
  if (!roster || !runsEl) return;

  function refreshMap() {
    if (!mapEl) return Promise.resolve();
    var view = byId("view-fleet");
    if (view && view.hidden) return Promise.resolve();
    return fetch("/api/mesh/map").then(readJson).then(function (d) {
      renderMeshMap(mapEl, d, mapStatus);
    }).catch(function (e) {
      renderMeshMap(mapEl, { ok: false, error: e.message || "map failed" }, mapStatus);
    });
  }

  function doRefresh() {
    if (refresh) refresh.disabled = true;
    if (statusEl) statusEl.textContent = "Loading\u2026";
    skeleton(roster, 2);
    skeleton(runsEl, 3);
    if (dmsEl) skeleton(dmsEl, 2);
    var statusP = fetch("/api/status").then(readJson).catch(function (e) { return { __err: e }; });
    var a2aP = fetch("/.well-known/agent.json").then(readJson).catch(function () { return null; });
    var runsP = fetch("/api/runs").then(readJson).then(function (d) {
      var txt = d.text || "";
      if (txt) { try { return JSON.parse(txt); } catch (_) { return []; } }
      return Array.isArray(d) ? d : (d.runs || []);
    }).catch(function (e) { return { __err: e }; });
    var roomsP = fetch("/api/chat/rooms").then(readJson).then(function (d) {
      if (d && d.ok === false && /disabled/i.test(d.error || "")) return null;
      return d;
    }).catch(function () { return null; });
    // Peer agent cards; null (module disabled, scan failed) degrades the
    // roster to bare name+url lines rather than blocking it.
    var peersP = fetch("/api/peers").then(readJson).catch(function () { return null; });
    refreshMap();
    return Promise.all([statusP, a2aP, runsP, roomsP, peersP]).then(function (vals) {
      var s = vals[0];
      var a2a = vals[1];
      var r = vals[2];
      var c = vals[3];
      var cards = vals[4];
      if (s && s.__err) renderError(roster, "Could not load roster: " + s.__err.message, doRefresh);
      else renderRoster(roster, s, a2a, cards);
      if (dmsEl) renderDMs(dmsEl, c);
      if (r && r.__err) renderError(runsEl, "Could not load runs: " + r.__err.message, doRefresh);
      else renderRuns(runsEl, detail, r || []);
      try { renderFloor(r && !r.__err ? r : [], s && !s.__err ? s : null); } catch (_) {}
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
  observeFloorTheme();
  if (refresh && !refresh._fleetBound) {
    refresh._fleetBound = true;
    refresh.addEventListener("click", doRefresh);
  }
  doRefresh();
  if (_meshTimer) clearInterval(_meshTimer);
  if (!initFleet._liveBound) {
    initFleet._liveBound = true;
    onLive(function (ev) {
      if (!ev) return;
      if (ev.t === "talk" || ev.t === "run" || ev.t === "mesh") refreshMap();
    });
  }
  _meshTimer = setInterval(function () {
    if (liveOk()) return;
    refreshMap();
  }, 2000);
  window.clankerFleet = window.clankerFleet || {};
  window.clankerFleet.refresh = function () { return doRefresh(); };
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initFleet);
} else {
  initFleet();
}
