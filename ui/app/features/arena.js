// Arena view: a judged debate rendered as a pixel battle, plus the transcript
// that is the actual source of truth.
//
// The canvas is decorative (aria-hidden) and carries nothing the transcript and
// the aria-live caption below it do not also carry in words. That split, the
// procedural block sprites, the hash-to-hue colours and the reduced-motion
// still-frame fallback are all Fleet's floor technique (features/fleet.js,
// _floorFrame) applied to a battle layout, not a new drawing framework.
//
// Reference: docs/prds/0008-arena.md, "Web UI: the arena view".

import { readJson, peerColor, themeToken, cssColorAlpha } from "../core/utils.js";
import { reducedMotion } from "../core/vendor.js";
import { onLive, liveOk } from "../core/stream.js";

function byId(id) { return document.getElementById(id); }

// Same hash-to-hue as the Fleet roster, so the same peer is the same colour in
// both views.
// The canvas palette is seeded from the active theme's computed tokens, not a
// fixed dark ramp: Fleet's bucket hues map onto the theme's ok/warn/danger and
// the stage neutrals onto surface/border, so a light data-theme draws a light
// stage and the status colours stay re-tunable. The palette is re-read on every
// draw/redraw; the theme observer in bindArena re-seeds static reduced-motion
// frames.
function withAlpha(color, a) {
  return cssColorAlpha(color, a);
}
function arenaTheme() {
  return {
    bg: themeToken("--surface-2"),
    surface: themeToken("--surface"),
    border: themeToken("--border"),
    fg: themeToken("--fg"),
    muted: themeToken("--fg-muted"),
    ok: themeToken("--ok"),
    warn: themeToken("--warn"),
    danger: themeToken("--danger")
  };
}

// Arena v2 (three.js) is an opt-in per-browser toggle; the module and the
// vendored three.js are only fetched on first use. `mode3d` mirrors the
// localStorage flag so render paths can branch synchronously.
var arena3d = null;
var mode3d = false;
try { mode3d = window.localStorage.getItem("arena3d") === "1"; } catch (_) {}

var state = {
  id: null,
  match: null,
  timer: null,
  raf: null,
  // Elimination order, so the compactor makes one pass per loser rather than a
  // pile-up (PRD phase 8 note).
  compactor: { queue: [], i: 0, started: 0, scene: 0 },
  lastMoveKey: "",
  // Consecutive failed polls. Reset by any answer, so it counts a run of
  // failures rather than a total.
  pollFails: 0
};

/* How many polls in a row may fail before the view stops following a running
   match. One is not a verdict on anything: this server answers one request per
   connection, so a poll landing while another tab or the CLI is mid-request is
   ordinary, and so is a laptop lid. */
var POLL_GIVE_UP = 5;

/* ------------------------------------------------------------------ polling */

/* Only while the match is running, stopped the moment it reaches a verdict.
   Never a standing background timer on a finished match. */
function startPolling() {
  stopPolling();
  state.pollFails = 0;
  state.timer = window.setInterval(function () {
    if (liveOk()) return;
    fetchMatch(state.id, true);
  }, 1100);
}
onLive(function (ev) {
  if (!ev || ev.t !== "arena" || !state.id) return;
  fetchMatch(state.id, true);
});

function stopPolling() {
  if (state.timer) { window.clearInterval(state.timer); state.timer = null; }
}

export function stopArena() {
  stopPolling();
  if (state.raf) { window.cancelAnimationFrame(state.raf); state.raf = null; }
  // The 3D stage's own loop already stops itself when the view hides; a full
  // stop tears it down so nothing GPU-side outlives the view.
  if (arena3d) { arena3d.unmountArena3D(); }
}

function fetchMatch(id, quiet) {
  if (!id) return Promise.resolve(null);
  var status = byId("arena-status");
  if (!quiet && status) status.textContent = "Loading match " + id + "…";
  return fetch("/api/arena/" + encodeURIComponent(id)).then(readJson).then(function (data) {
    if (!data || !data.ok || !data.match) throw new Error((data && data.error) || "no such match");
    state.id = id;
    // The address bar names the open match, so it can be bookmarked and
    // shared the way #runs/<id> can.
    try {
      var want = "#arena/" + encodeURIComponent(id);
      if (location.hash !== want) history.replaceState(null, "", want);
    } catch (_) {}
    var wasRunning = state.match && state.match.status === "running";
    state.pollFails = 0;
    state.match = data.match;
    renderMatch();
    if (data.match.status === "running") {
      if (!state.timer) startPolling();
    } else {
      stopPolling();
      // A match that finished while we were watching gets the compactor; one
      // that was already over when opened does not replay it unasked.
      if (wasRunning) queueCompactor();
    }
    return data.match;
  }).catch(function (err) {
    // A poll that failed is a poll, not a verdict on the match. Stopping the
    // timer on the first one meant a single reset connection froze a running
    // match on screen for good: the stage kept its last frame, the status line
    // said only what had gone wrong, and nothing was still asking. The last
    // known state stays up while it retries, and it gives up out loud.
    if (quiet) {
      state.pollFails += 1;
      if (state.pollFails < POLL_GIVE_UP) return null;
      stopPolling();
      if (status) {
        status.textContent = "Lost track of match " + id + " after " + state.pollFails +
          " failed updates (" + err.message + "). Refresh to pick it up again.";
      }
      return null;
    }
    stopPolling();
    if (status) status.textContent = "Could not load match: " + err.message;
    return null;
  });
}

export function loadArenaView() {
  var status = byId("arena-status");
  if (status) status.textContent = "Loading matches…";
  // A #arena/<id> deep link (bookmark, palette, another view) names the match
  // to open; consumed once, the way board/knowledge pending ids are.
  if (window._pendingArenaId) {
    state.id = window._pendingArenaId;
    window._pendingArenaId = null;
  }
  return fetch("/api/arena").then(readJson).then(function (data) {
    var matches = (data && data.matches) || [];
    state.matches = matches;
    renderPicker(matches);
    if (!matches.length) {
      if (status) status.textContent = "No matches yet. Run one with: clanker arena \"<question>\" --for X --against Y";
      var stage = byId("arena-stage");
      if (stage) stage.hidden = true;
      var chips = byId("arena-combatants");
      if (chips) chips.textContent = "";
      var graph = byId("arena-graph");
      if (graph) graph.hidden = true;
      return null;
    }
    // Newest first from the tool, so the top row is the one just finished.
    return fetchMatch(state.id || matches[0].id, false);
  }).catch(function (err) {
    if (status) status.textContent = "Could not load matches: " + err.message;
  });
}

/* ----------------------------------------------------------------- picker */

function renderPicker(matches) {
  var host = byId("arena-list");
  if (!host) return;
  host.textContent = "";
  matches.forEach(function (m) {
    var row = document.createElement("button");
    row.type = "button";
    row.className = "secondary arena-pick";
    row.setAttribute("aria-pressed", m.id === state.id ? "true" : "false");
    // The lamp says how it ended at a glance: green a verdict, amber still
    // running, grey a draw. Same vocabulary as the rest of the panel.
    var lamp = document.createElement("span");
    lamp.className = "arena-lamp";
    var running = !m.winner && !m.headline;
    lamp.dataset.state = running ? "running" : (m.winner === "draw" ? "draw" : "done");
    lamp.setAttribute("aria-hidden", "true");
    var q = document.createElement("span");
    q.className = "arena-pick-q";
    q.textContent = m.question || m.id;
    q.title = m.question || m.id;
    var who = document.createElement("span");
    who.className = "meta arena-pick-outcome";
    // The words follow the same test the lamp does. Reading only `winner` made
    // a finished match that named nobody, a mutual concession, read as still
    // running next to a lamp that said it was over.
    who.textContent = running
      ? "running"
      : (m.winner ? (m.winner === "draw" ? "draw" : m.winner + " won") : "no verdict");
    row.appendChild(lamp);
    row.appendChild(q);
    row.appendChild(who);
    row.addEventListener("click", function () {
      state.compactor = { queue: [], i: 0, started: 0, scene: 0 };
      fetchMatch(m.id, false).then(function () { renderPicker(matches); });
    });
    host.appendChild(row);
  });
}

/* -------------------------------------------------------------- transcript */

/* The canvas never carries information this does not also carry in words. */
function renderTranscript(m) {
  var host = byId("arena-transcript");
  if (!host) return;
  host.textContent = "";

  var head = document.createElement("p");
  head.className = "meta";
  var judge = m.judge === "third" ? "third-party judge" : "self-reported judging";
  if (m.judge_provider) judge += " (" + m.judge_provider + ")";
  if (m.judge_downgraded) judge += ", downgraded: " + m.judge_downgraded;
  head.textContent = (m.combatants || []).length + " positions, round " + m.rounds_played + " of " + m.max_rounds + ", " + judge + ".";
  host.appendChild(head);

  (m.combatants || []).forEach(function (c) {
    var p = document.createElement("p");
    p.className = "meta";
    var out = c.eliminated ? " eliminated" : (c.conceded ? " conceded" : "");
    p.textContent = c.label + " — \"" + c.position + "\" — " + c.hp + "/" + c.max_hp + " HP" + out;
    host.appendChild(p);
  });

  (m.rounds || []).forEach(function (r, ri) {
    var fold = document.createElement("details");
    fold.className = "arena-round";
    // The newest round is the one being followed; older rounds fold away so
    // a long match stays scannable, like the transcript's tool cards.
    fold.open = ri === (m.rounds.length - 1);
    var h = document.createElement("summary");
    h.textContent = "Round " + r.round + " — " + (r.moves || []).length + " move(s)";
    fold.appendChild(h);
    host.appendChild(fold);
    (r.moves || []).forEach(function (mv) {
      var card = document.createElement("div");
      card.className = "tool-card";
      var title = document.createElement("div");
      title.className = "tool-card-head";
      var bits = [mv.label, mv.move];
      if (mv.target_label && mv.target_label !== mv.label) bits.push("at " + mv.target_label);
      var nums = [];
      if (mv.damage_taken) nums.push("-" + mv.damage_taken + " HP");
      if (mv.blocked) nums.push("blocked " + mv.blocked);
      if (mv.damage_dealt) nums.push("deals " + mv.damage_dealt);
      nums.push(mv.hp_after + " HP left");
      title.textContent = bits.join(" ") + " · " + nums.join(", ");
      card.appendChild(title);
      var body = document.createElement("div");
      body.className = "tool-card-body";
      body.textContent = mv.forfeit ? ("forfeited the round: " + (mv.error || "no reply")) : mv.text;
      card.appendChild(body);
      var flags = [];
      if (mv.weak) flags.push("did not parse as a move, scored weak");
      if (mv.truncated) flags.push("cut off, force capped");
      if (mv.retargeted) flags.push("named no target");
      if (mv.judged_by) flags.push("scored " + mv.judged_by);
      if (mv.judge_note) flags.push("judge: " + mv.judge_note);
      if (flags.length) {
        var meta = document.createElement("div");
        meta.className = "meta";
        meta.textContent = flags.join(" · ");
        card.appendChild(meta);
      }
      fold.appendChild(card);
    });
  });

  if (m.verdict) {
    var v = document.createElement("div");
    v.className = "tool-card arena-verdict";
    var vh = document.createElement("div");
    vh.className = "tool-card-head";
    vh.textContent = "Verdict: " + m.verdict.headline;
    var vb = document.createElement("div");
    vb.className = "tool-card-body";
    vb.textContent = m.verdict.answer || "";
    v.appendChild(vh);
    v.appendChild(vb);
    host.appendChild(v);
  }
}

/* ------------------------------------------------------------- status text */

/* The authoritative account of the stage, in words. This is what a screen
   reader gets, and what a reduced-motion session gets instead of animation. */
function statusLine(m) {
  if (!m) return "";
  if (m.status === "running") {
    var last = lastMove(m);
    if (!last) return "Round 1: composing opening arguments.";
    var s = "Round " + last.round + ": " + last.label + " " + last.move;
    if (last.target_label && last.target_label !== last.label) s += " at " + last.target_label;
    if (last.damage_taken) s += " (-" + last.damage_taken + " HP)";
    else if (last.blocked) s += " (blocked " + last.blocked + ")";
    s += ". Waiting on the next reply.";
    return s;
  }
  var out = m.verdict ? m.verdict.headline : "Match finished.";
  var gone = (m.combatants || []).filter(function (c) { return c.eliminated; });
  if (gone.length) out += " " + gone.map(function (c) { return c.label; }).join(", ") + (gone.length === 1 ? " eliminated." : " eliminated.");
  return out;
}

function lastMove(m) {
  var rounds = m.rounds || [];
  for (var i = rounds.length - 1; i >= 0; i--) {
    var mv = rounds[i].moves || [];
    if (mv.length) return mv[mv.length - 1];
  }
  return null;
}

/* ------------------------------------------------------------ the compactor */

/* Queue one bulldozer pass per eliminated combatant, in elimination order. */
function queueCompactor() {
  if (reducedMotion.matches) return;
  var m = state.match;
  if (!m) return;
  var order = [];
  (m.rounds || []).forEach(function (r) {
    (r.moves || []).forEach(function (mv) {
      if (mv.hp_after <= 0 && order.indexOf(mv.combatant) === -1) order.push(mv.combatant);
    });
  });
  (m.combatants || []).forEach(function (c, i) {
    if (c.eliminated && order.indexOf(i) === -1) order.push(i);
  });
  state.compactor = { queue: order, i: 0, started: 0, scene: 0 };
}

/* --------------------------------------------------------------- rendering */

function renderMatch() {
  var m = state.match;
  if (!m) return;
  var stage = byId("arena-stage");
  if (stage) stage.hidden = false;

  var status = byId("arena-status");
  if (status) {
    var line = statusLine(m);
    if (reducedMotion.matches) line = "Still frame, respecting reduced motion. " + line;
    if (status.textContent !== line) status.textContent = line;
  }

  renderCombatants(m);
  renderHpGraph(m);
  renderTranscript(m);

  // A new move restarts the pose clock, so the lunge plays on arrival rather
  // than whenever the frame loop happens to be.
  var last = lastMove(m);
  var key = last ? (last.round + ":" + last.combatant + ":" + last.move) : "";
  if (key !== state.lastMoveKey) {
    state.lastMoveKey = key;
    state.poseStart = performance.now();
  }

  if (mode3d) {
    // The 3D stage replaces only the decorative canvas; chips, graph and
    // transcript above are the record either way. The 2D loop stays off.
    if (state.raf) { window.cancelAnimationFrame(state.raf); state.raf = null; }
    syncStageMode();
    ensure3d().then(function (mod) {
      if (mod && mode3d) mod.updateArena3D(state.match);
    });
    return;
  }
  if (reducedMotion.matches) {
    // One static frame of the current state, no loop scheduled at all.
    if (state.raf) { window.cancelAnimationFrame(state.raf); state.raf = null; }
    drawFrame(performance.now());
    return;
  }
  if (!state.raf) state.raf = window.requestAnimationFrame(frame);
}

/* -------------------------------------------------------------- 3D toggle */

// Shows one of the two decorative stages. Both live inside #arena-stage so
// the aria-hidden/decorative contract is inherited rather than repeated.
function syncStageMode() {
  var cv = byId("arena-canvas");
  var host = byId("arena-stage3d");
  if (cv) cv.hidden = mode3d;
  if (host) host.hidden = !mode3d;
  var btn = byId("arena-3d-toggle");
  if (btn) btn.setAttribute("aria-pressed", mode3d ? "true" : "false");
}

function ensure3d() {
  if (arena3d) return Promise.resolve(arena3d);
  return import("./arena3d.js").then(function (mod) {
    arena3d = mod;
    var host = byId("arena-stage3d");
    return mod.mountArena3D(host).then(function () { return mod; });
  }).catch(function (err) {
    // three failing to load (old browser, no WebGL) falls back to 2D and
    // says so once, rather than a blank stage.
    mode3d = false;
    try { window.localStorage.setItem("arena3d", "0"); } catch (_) {}
    syncStageMode();
    var status = byId("arena-status");
    if (status) status.textContent = "3D stage unavailable (" + err.message + "); using the 2D stage.";
    renderMatch();
    return null;
  });
}

function toggle3d() {
  mode3d = !mode3d;
  try { window.localStorage.setItem("arena3d", mode3d ? "1" : "0"); } catch (_) {}
  if (!mode3d && arena3d) arena3d.unmountArena3D();
  syncStageMode();
  renderMatch();
}

function frame(ts) {
  state.raf = null;
  var cv = byId("arena-canvas");
  // Stop the loop when the view is closed: a hidden canvas animating is the
  // background timer this view is not allowed to leave running.
  if (!cv || (cv.closest && cv.closest("#arena-stage[hidden]")) || !document.body.contains(cv)) return;
  var view = byId("view-arena");
  if (view && view.hidden) return;
  drawFrame(ts);
  state.raf = window.requestAnimationFrame(frame);
}

function hpColor(frac, pal) {
  if (frac > 0.5) return pal.ok;
  if (frac > 0.2) return pal.warn;
  return pal.danger;
}

function drawFrame(ts) {
  var cv = byId("arena-canvas");
  if (!cv) return;
  var ctx = cv.getContext("2d");
  if (!ctx) return;
  var m = state.match;
  if (!m) return;
  var reduced = reducedMotion.matches;
  var t = reduced ? 0 : (ts || 0);
  var cs = m.combatants || [];
  var n = cs.length || 1;
  var pal = arenaTheme();

  ctx.imageSmoothingEnabled = false;
  ctx.clearRect(0, 0, cv.width, cv.height);

  // Ground plane and horizon, toned from the active theme rather than a fixed
  // dark ramp, tiled the same way as Fleet's desk floor.
  ctx.fillStyle = pal.bg;
  ctx.fillRect(0, 0, cv.width, cv.height);
  ctx.fillStyle = withAlpha(pal.fg, 0.04);
  for (var gx = 0; gx < cv.width; gx += 8) ctx.fillRect(gx, 0, 1, cv.height);
  var ground = cv.height - 46;
  ctx.fillStyle = pal.surface;
  ctx.fillRect(0, ground, cv.width, 2);
  ctx.fillStyle = pal.border;
  for (var tx = 0; tx < cv.width; tx += 16) ctx.fillRect(tx + 1, ground + 2, 14, 26);

  var last = lastMove(m);
  var poseAge = state.poseStart ? (t - state.poseStart) : 1e9;
  var lunge = reduced ? 0 : Math.max(0, 1 - poseAge / 420);

  var cw = cv.width / n;
  for (var i = 0; i < n; i++) {
    var c = cs[i];
    var cx = Math.floor(i * cw + cw / 2);
    // Pairwise faces the two sprites across the centre; a royale lines them up.
    var facing = n <= 2 ? (i === 0 ? 1 : -1) : (cx < cv.width / 2 ? 1 : -1);
    var acting = last && last.combatant === i ? last.move : null;
    drawCombatant(ctx, cv, c, i, cx, ground, facing, acting, t, lunge, reduced, m, pal);
  }

  // The compactor runs after the verdict, over the top of the still stage.
  if (!reduced && m.status !== "running") drawCompactor(ctx, cv, m, t, ground, cw, pal);
}

function drawCombatant(ctx, cv, c, i, cx, ground, facing, acting, t, lunge, reduced, m, pal) {
  var gone = c.eliminated || c.conceded;
  var bob = reduced || gone ? 0 : Math.sin(t / 420 + i * 1.1) * 2;
  var kneel = c.conceded || c.eliminated ? 8 : 0;
  // A lunge translates toward centre for a few frames; same t-driven timing as
  // the idle bob, larger amplitude.
  var push = (acting === "attack" || acting === "counter" || acting === "final_stand") ? Math.round(lunge * 10) * facing : 0;
  var bx = cx - 9 + push;
  var by = ground - 34 + bob + kneel;

  ctx.globalAlpha = gone ? 0.45 : 1;
  ctx.fillStyle = peerColor(c.label || String(i));
  // head, torso
  ctx.fillRect(bx + 5, by - 8, 8, 8);
  ctx.fillRect(bx + 2, by, 14, 18 - kneel);
  // arms by pose
  if (acting === "block" || acting === "counter") {
    // arms up, held through the opponent's lunge frame
    ctx.fillRect(bx - 2, by - 6, 5, 4);
    ctx.fillRect(bx + 15, by - 6, 5, 4);
  } else if (acting === "attack" || acting === "final_stand") {
    ctx.fillRect(facing > 0 ? bx + 14 : bx - 4, by + 3, 8, 3);
  } else {
    ctx.fillRect(bx - 2, by + 4, 4, 3);
    ctx.fillRect(bx + 14, by + 4, 4, 3);
  }
  // A winner holds an arms-up pose with the lamp-glow breathing technique.
  if (m.verdict && m.verdict.winner === i) {
    var breathe = reduced ? 1 : 0.6 + 0.4 * Math.sin(t / 900);
    ctx.fillRect(bx - 2, by - 10, 5, 4);
    ctx.fillRect(bx + 15, by - 10, 5, 4);
    ctx.globalAlpha = breathe;
    ctx.fillStyle = pal.ok;
    ctx.fillRect(bx + 2, by - 18, 14, 3);
    ctx.globalAlpha = gone ? 0.45 : 1;
  }
  ctx.globalAlpha = 1;

  // A brief flash on a sprite that blocked.
  if ((acting === "block" || acting === "counter") && !reduced && lunge > 0.4) {
    ctx.globalAlpha = 0.35 * lunge;
    ctx.fillStyle = pal.fg;
    ctx.fillRect(bx - 2, by - 10, 20, 30);
    ctx.globalAlpha = 1;
  }

  // Segmented HP bar, SNES style, above the sprite.
  var segs = 10;
  var maxHp = c.max_hp || 100;
  var filled = Math.max(0, Math.min(segs, Math.round((c.hp / maxHp) * segs)));
  var barX = cx - 22;
  var barY = ground - 52;
  ctx.globalAlpha = gone ? 0.4 : 1;
  for (var s = 0; s < segs; s++) {
    ctx.fillStyle = s < filled ? hpColor(c.hp / maxHp, pal) : pal.border;
    ctx.fillRect(barX + s * 4.4, barY, 3, 5);
  }
  ctx.globalAlpha = 1;

  // A floating damage number that rises and fades, same 10px monospace Fleet
  // uses for its desk labels.
  var lm = lastMove(m);
  if (lm && lm.combatant === i && lm.damage_taken > 0 && !reduced && lunge > 0) {
    ctx.globalAlpha = lunge;
    ctx.fillStyle = pal.danger;
    ctx.font = "10px monospace";
    ctx.textAlign = "center";
    ctx.fillText("-" + lm.damage_taken, cx, barY - 6 - Math.round((1 - lunge) * 10));
    ctx.globalAlpha = 1;
  }

  ctx.fillStyle = pal.fg;
  ctx.font = "10px monospace";
  ctx.textAlign = "center";
  ctx.fillText((c.label || "").slice(0, 14), cx, ground + 40);
}

/* The eliminated combatant's exit: a bulldozer pass, then walls closing in.
   Purely decorative, and the status line already said who lost in words. */
function drawCompactor(ctx, cv, m, t, ground, cw, pal) {
  var q = state.compactor;
  if (!q.queue.length || q.i >= q.queue.length) return;
  if (!q.started) q.started = t;
  var age = t - q.started;
  var pushMs = 2200, wallMs = 1500;

  var idx = q.queue[q.i];
  var cs = m.combatants || [];
  var cx = Math.floor(idx * cw + cw / 2);
  var hole = cv.width - 26;

  if (age < pushMs) {
    var p = age / pushMs;
    // Dark hole at the far edge.
    ctx.fillStyle = pal ? pal.bg : "#0b0e0f";
    ctx.fillRect(hole, ground - 16, 22, 18);
    // The loser's sprite, pushed ahead of the blade, shrinking into the hole.
    var lx = Math.round(cx + (hole - cx) * p);
    var scale = 1 - 0.7 * p;
    ctx.globalAlpha = 1 - 0.8 * p;
    ctx.fillStyle = peerColor((cs[idx] && cs[idx].label) || String(idx));
    var h = Math.round(20 * scale);
    ctx.fillRect(lx, ground - h, Math.round(12 * scale), h);
    ctx.globalAlpha = 1;
    // Bulldozer: body, blade, two treads that step-cycle on the same t.
    var bx = Math.round(cx - 40 + (hole - cx) * p);
    ctx.fillStyle = pal ? pal.warn : "#e5b54a";
    ctx.fillRect(bx, ground - 18, 24, 12);
    ctx.fillStyle = pal ? pal.warn : "#c9a038";
    ctx.fillRect(bx + 24, ground - 20, 4, 16);
    ctx.fillStyle = pal ? pal.surface : "#2a3033";
    var step = Math.floor(t / 90) % 2;
    ctx.fillRect(bx + 2 + step, ground - 6, 7, 6);
    ctx.fillRect(bx + 14 - step, ground - 6, 7, 6);
    return;
  }

  if (age < pushMs + wallMs) {
    // Crossfade to the walls closing on the now-small sprite. They hold just
    // short of full closure: the point is the walls closing.
    var w = (age - pushMs) / wallMs;
    ctx.globalAlpha = Math.min(1, w * 3);
    ctx.fillStyle = pal ? pal.bg : "#121618";
    ctx.fillRect(0, 0, cv.width, cv.height);
    var gap = 26;
    var travel = Math.round((cv.width / 2 - gap) * Math.min(1, w * 1.2));
    ctx.fillStyle = pal ? pal.border : "#3a4146";
    ctx.fillRect(0, 0, travel, cv.height);
    ctx.fillRect(cv.width - travel, 0, travel, cv.height);
    ctx.fillStyle = peerColor((cs[idx] && cs[idx].label) || String(idx));
    ctx.fillRect(cv.width / 2 - 5, cv.height / 2 - 6, 10, 14);
    ctx.globalAlpha = 1;
    return;
  }

  // Next loser gets its own pass, one at a time, rather than a pile-up.
  q.i += 1;
  q.started = 0;
}

/* -------------------------------------------------- combatants and HP graph */

/* One chip per combatant: label, live HP bar, outcome. The DOM version of
   what the stage draws, so none of it is pixels-only. */
function renderCombatants(m) {
  var host = byId("arena-combatants");
  if (!host) return;
  host.textContent = "";
  var pal = arenaTheme();
  (m.combatants || []).forEach(function (c, i) {
    var chip = document.createElement("div");
    chip.className = "arena-combatant";
    if (c.eliminated || c.conceded) chip.dataset.out = "true";
    if (m.verdict && m.verdict.winner === i) chip.dataset.winner = "true";
    var dot = document.createElement("span");
    dot.className = "arena-swatch";
    dot.style.background = peerColor(c.label || String(i));
    dot.setAttribute("aria-hidden", "true");
    var name = document.createElement("span");
    name.className = "arena-combatant-name";
    name.textContent = c.label || ("#" + (i + 1));
    if (c.persona) name.title = c.persona;
    var bar = document.createElement("span");
    bar.className = "arena-hp";
    bar.setAttribute("role", "img");
    bar.setAttribute("aria-label", (c.label || "") + " " + c.hp + " of " + (c.max_hp || 100) + " HP");
    var fill = document.createElement("span");
    fill.className = "arena-hp-fill";
    var frac = (c.max_hp ? c.hp / c.max_hp : 0);
    fill.style.width = Math.max(0, Math.min(100, Math.round(frac * 100))) + "%";
    fill.style.background = hpColor((c.max_hp ? c.hp / c.max_hp : 0), pal);
    bar.appendChild(fill);
    var hp = document.createElement("span");
    hp.className = "meta";
    hp.textContent = c.hp + " HP" + (c.eliminated ? " · eliminated" : (c.conceded ? " · conceded" : ""));
    chip.appendChild(dot);
    chip.appendChild(name);
    chip.appendChild(bar);
    chip.appendChild(hp);
    host.appendChild(chip);
  });
}

/* HP over the match as one stepped line per combatant, on the shared move
   axis: the transcript's numbers as a picture. Static by nature, so reduced
   motion needs no special case beyond not existing to animate. */
function renderHpGraph(m) {
  var fold = byId("arena-graph");
  var cv = byId("arena-hp-canvas");
  var caption = byId("arena-graph-caption");
  if (!fold || !cv) return;
  var cs = m.combatants || [];
  // Series: every combatant starts at max and steps at each of its moves.
  var moves = [];
  (m.rounds || []).forEach(function (r) {
    (r.moves || []).forEach(function (mv) { moves.push(mv); });
  });
  if (!moves.length) { fold.hidden = true; return; }
  fold.hidden = false;
  var series = cs.map(function (c) { return [c.max_hp || 100]; });
  moves.forEach(function (mv) {
    cs.forEach(function (c, i) {
      var prev = series[i][series[i].length - 1];
      series[i].push(mv.combatant === i ? mv.hp_after : prev);
    });
  });
  var ctx = cv.getContext("2d");
  var W = cv.width, H = cv.height;
  var padL = 26, padR = 8, padT = 8, padB = 16;
  var pal = arenaTheme();
  ctx.clearRect(0, 0, W, H);
  ctx.fillStyle = pal.bg;
  ctx.fillRect(0, 0, W, H);
  var maxHp = 0;
  cs.forEach(function (c) { maxHp = Math.max(maxHp, c.max_hp || 100); });
  var nx = series[0].length - 1 || 1;
  function X(k) { return padL + (W - padL - padR) * (k / nx); }
  function Y(hp) { return padT + (H - padT - padB) * (1 - hp / maxHp); }
  // Gridlines at 0/50/100% with axis labels, same ink as the stage.
  ctx.strokeStyle = withAlpha(pal.fg, 0.08);
  ctx.fillStyle = pal.muted;
  ctx.font = "9px monospace";
  ctx.textAlign = "right";
  [0, 0.5, 1].forEach(function (f) {
    var y = Y(maxHp * f);
    ctx.beginPath();
    ctx.moveTo(padL, y);
    ctx.lineTo(W - padR, y);
    ctx.stroke();
    ctx.fillText(String(Math.round(maxHp * f)), padL - 3, y + 3);
  });
  // Round boundaries as faint verticals, so the x axis means something.
  var moveIdx = 0;
  ctx.textAlign = "center";
  (m.rounds || []).forEach(function (r) {
    var upto = moveIdx + (r.moves || []).length;
    var x = X(upto);
    ctx.strokeStyle = withAlpha(pal.fg, 0.05);
    ctx.beginPath();
    ctx.moveTo(x, padT);
    ctx.lineTo(x, H - padB);
    ctx.stroke();
    ctx.fillText("R" + r.round, X(moveIdx + (r.moves || []).length / 2), H - 5);
    moveIdx = upto;
  });
  // The lines themselves, stepped: HP only changes ON a move.
  series.forEach(function (pts, i) {
    ctx.strokeStyle = peerColor(cs[i].label || String(i));
    ctx.lineWidth = 2;
    ctx.beginPath();
    pts.forEach(function (hp, k) {
      var x = X(k), y = Y(hp);
      if (k === 0) ctx.moveTo(x, y);
      else { ctx.lineTo(x, Y(pts[k - 1])); ctx.lineTo(x, y); }
    });
    ctx.stroke();
  });
  if (caption) {
    caption.textContent = cs.map(function (c, i) {
      return c.label + " " + series[i][series[i].length - 1] + " HP";
    }).join(" · ") + " after " + moves.length + " moves.";
  }
}

/* -------------------------------------------------------------------- bind */

export function bindArena() {
  var refresh = byId("arena-refresh");
  if (refresh) refresh.addEventListener("click", function () { loadArenaView(); });
  var t3d = byId("arena-3d-toggle");
  if (t3d) t3d.addEventListener("click", toggle3d);
  syncStageMode();
  // Reduced motion can be toggled while the page is open; honour it live rather
  // than only at load.
  if (window.matchMedia) {
    var mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    if (mq.addEventListener) mq.addEventListener("change", function () { renderMatch(); });
  }
  // A theme switch must re-seed the palette; re-render draws from the new
  // tokens, and a reduced-motion static frame is redrawn too.
  var root = document.documentElement;
  if (root && typeof MutationObserver !== "undefined") {
    new MutationObserver(function () {
      if (arena3d) arena3d.retheme();
      renderMatch();
    }).observe(root, { attributes: true, attributeFilter: ["data-theme"] });
  }
}
