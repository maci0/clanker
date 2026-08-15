// Schedule view: what `clanker schedule` has been asked to run, when each
// entry fires next, how the last fire went, and a switch per entry.
//
// Read-and-toggle, matching GET /api/schedule and POST /api/schedule/<id>.
// Firing an entry is an agent run and this server answers one request per
// connection, so `run` and `run-due` stay with the system's cron and the
// terminal, the same line the Arena and Compare views draw. Adding an entry
// stays there too: `add` has to reject a spec that never fires and say which
// of the spec and the task was wrong, and a form that quietly accepted one
// would be worse than no form.
//
// Nothing here fires on its own either — see docs/prds/0009-schedule.md and
// ADR 0008. If the ledger is empty while entries look due, the answer is
// almost always that nothing is calling `run-due`, so the empty state says so
// rather than leaving the reader to wonder.
import { readJson, fmtMs } from "../core/utils.js";
import { showLoadError } from "../core/ui.js";

function byId(id) { return document.getElementById(id); }

var state = { entries: [], log: [], busy: "", error: "" };

/* Entry times are read at the entry's own fixed UTC offset (never a DST-aware
   zone), so they are rendered at that offset rather than in the browser's
   locale — a row that says 09:00 has to mean the 09:00 the cron field names. */
function stampAt(secs, offsetMinutes) {
  if (!secs) return "";
  var shifted = new Date((secs + (offsetMinutes || 0) * 60) * 1000);
  var p = function (n) { return String(n).padStart(2, "0"); };
  var text = shifted.getUTCFullYear() + "-" + p(shifted.getUTCMonth() + 1) + "-" + p(shifted.getUTCDate()) +
    " " + p(shifted.getUTCHours()) + ":" + p(shifted.getUTCMinutes());
  if (!offsetMinutes) return text + " UTC";
  var sign = offsetMinutes < 0 ? "-" : "+";
  var abs = Math.abs(offsetMinutes);
  return text + " " + sign + p(Math.floor(abs / 60)) + ":" + p(abs % 60);
}

function relative(secs) {
  if (!secs) return "";
  var delta = secs - Math.floor(Date.now() / 1000);
  var ahead = delta >= 0;
  var n = Math.abs(delta);
  var unit;
  if (n < 60) unit = n + "s";
  else if (n < 3600) unit = Math.round(n / 60) + "m";
  else if (n < 86400) unit = Math.round(n / 3600) + "h";
  else unit = Math.round(n / 86400) + "d";
  return ahead ? "in " + unit : unit + " ago";
}

/* What the row says under "next". Mirrors `clanker schedule list`'s own
   column, including the two cases that are not a time: the server leaves
   next_run out when an entry can never fire, and this has to tell the two
   reasons apart because only one of them is the user's doing. */
function nextText(e) {
  if (!e.enabled) return "paused";
  if (!e.next_run) return "never: check the cron spec";
  var when = stampAt(e.next_run, e.tz_offset_minutes);
  if (e.next_run <= Math.floor(Date.now() / 1000)) return "due now · " + when;
  return when + " · " + relative(e.next_run);
}

function statusChip(e) {
  var chip = document.createElement("span");
  chip.className = "meta schedule-status";
  if (!e.runs) { chip.textContent = "never run"; return chip; }
  var ok = e.last_status !== "error";
  chip.dataset.state = ok ? "ok" : "error";
  chip.textContent = (ok ? "ok" : "failed") + " · " + relative(e.last_run);
  chip.title = e.runs + (e.runs === 1 ? " run" : " runs") +
    (e.failures ? ", " + e.failures + " failed" : ", none failed");
  return chip;
}

function entryRow(e) {
  var row = document.createElement("article");
  row.className = "schedule-entry";
  if (!e.enabled) row.dataset.paused = "true";

  var head = document.createElement("div");
  head.className = "schedule-entry-head";
  var id = document.createElement("code");
  id.className = "schedule-id";
  id.textContent = e.id;
  head.appendChild(id);
  var cron = document.createElement("code");
  cron.className = "schedule-cron";
  cron.textContent = e.cron;
  cron.title = "Read at " + (e.tz_offset_minutes ? "offset " + e.tz_offset_minutes + " minutes" : "UTC");
  head.appendChild(cron);
  head.appendChild(statusChip(e));
  row.appendChild(head);

  // The task is a prompt the model was handed; it reaches the DOM as a text
  // node and there is no interpolation step here to escape.
  var task = document.createElement("p");
  task.className = "schedule-task";
  task.textContent = e.task;
  row.appendChild(task);

  var foot = document.createElement("div");
  foot.className = "schedule-entry-foot";
  var next = document.createElement("span");
  next.className = "meta schedule-next";
  next.textContent = nextText(e);
  foot.appendChild(next);

  if (e.provider) {
    var who = document.createElement("span");
    who.className = "meta";
    who.textContent = e.provider + (e.model ? " / " + e.model : "");
    foot.appendChild(who);
  }

  var toggle = document.createElement("button");
  toggle.type = "button";
  toggle.className = "secondary schedule-toggle";
  toggle.textContent = e.enabled ? "Pause" : "Resume";
  toggle.setAttribute("aria-label", (e.enabled ? "Pause " : "Resume ") + e.id);
  toggle.disabled = state.busy === e.id;
  toggle.addEventListener("click", function () { setEnabled(e.id, !e.enabled); });
  foot.appendChild(toggle);
  row.appendChild(foot);
  return row;
}

function logRow(r) {
  var li = document.createElement("li");
  li.className = "schedule-log-row";
  li.dataset.state = r.ok ? "ok" : "error";
  var when = document.createElement("span");
  when.className = "meta";
  when.textContent = relative(r.ts);
  var who = document.createElement("code");
  who.textContent = r.id;
  var what = document.createElement("span");
  var bits = [r.ok ? "ok" : "failed", r.trigger];
  if (r.duration_ms) bits.push(fmtMs(r.duration_ms));
  if (r.skipped) bits.push(r.skipped + " window(s) skipped");
  if (r.err) bits.push(r.err);
  what.textContent = bits.join(" · ");
  li.appendChild(when);
  li.appendChild(who);
  li.appendChild(what);
  return li;
}

function render() {
  var list = byId("schedule-list");
  var logHost = byId("schedule-log");
  var status = byId("schedule-status");
  if (list) {
    list.textContent = "";
    if (!state.entries.length) {
      var empty = document.createElement("p");
      empty.className = "run-empty";
      empty.appendChild(document.createTextNode("Nothing scheduled. Add one with"));
      empty.appendChild(document.createElement("br"));
      var cmd = document.createElement("code");
      cmd.textContent = "clanker schedule add \"*/30 * * * *\" \"<task>\"";
      empty.appendChild(cmd);
      list.appendChild(empty);
    } else state.entries.forEach(function (e) { list.appendChild(entryRow(e)); });
  }
  if (logHost) {
    logHost.textContent = "";
    if (!state.log.length) {
      var none = document.createElement("li");
      none.className = "meta";
      // The single most common reason for entries that look due and a ledger
      // that stays empty.
      none.textContent = state.entries.length
        ? "Nothing has fired yet. Entries only run when something calls `clanker schedule run-due`, usually a cron line, once a minute."
        : "Nothing has fired yet.";
      logHost.appendChild(none);
    } else state.log.forEach(function (r) { logHost.appendChild(logRow(r)); });
  }
  if (status) {
    // A failed toggle has to survive the redraw that re-enables its button.
    // The count is always true and therefore always available; what went
    // wrong is said once and is the only thing worth the line while it holds.
    if (state.error) { status.textContent = state.error; return; }
    var on = state.entries.filter(function (e) { return e.enabled; }).length;
    status.textContent = state.entries.length
      ? state.entries.length + (state.entries.length === 1 ? " entry" : " entries") + ", " + on + " active."
      : "No entries.";
  }
}

export function loadScheduleView() {
  var status = byId("schedule-status");
  if (status) status.textContent = "Loading schedule…";
  return fetch("/api/schedule").then(readJson).then(function (data) {
    state.entries = (data && data.entries) || [];
    state.log = (data && data.log) || [];
    // Refresh is also how you clear a failed toggle's message: the schedule
    // just came back clean, so the last failure no longer describes it.
    state.error = "";
    render();
    return data;
  }).catch(function (err) {
    var msg = "Could not load the schedule: " + err.message;
    if (status) status.textContent = msg;
    showLoadError(byId("schedule-list"), msg, loadScheduleView);
  });
}

/* One POST, the same store `clanker schedule enable|disable` writes, so a
   browser toggle and a terminal toggle are one recording path. The reply
   carries the rewritten entry (its next fire time has moved, because enabling
   re-dates the window from now), so the row is redrawn from the server's
   answer rather than from what the click assumed. */
function setEnabled(id, on) {
  if (state.busy) return Promise.resolve(null);
  state.busy = id;
  state.error = "";
  render();
  var status = byId("schedule-status");
  if (status) status.textContent = (on ? "Resuming " : "Pausing ") + id + "…";
  return fetch("/api/schedule/" + encodeURIComponent(id), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ enabled: on })
  }).then(readJson).then(function (data) {
    if (!data || !data.entry) throw new Error("the schedule did not come back");
    state.entries = state.entries.map(function (e) { return e.id === data.entry.id ? data.entry : e; });
    return data;
  }).catch(function (err) {
    state.error = "Could not update " + id + ": " + err.message;
    return null;
  }).then(function (out) {
    // Unconditionally, including after a failure. The row's Pause/Resume is
    // disabled off state.busy, so skipping the redraw on the error path left
    // the button greyed out for the rest of the visit: a server that refused
    // once meant a switch that could never be tried again without reloading
    // the view. The error text is carried in state.error so this redraw
    // reports it rather than overwriting it with the entry count.
    state.busy = "";
    render();
    return out;
  });
}

export function bindSchedule() {
  var refresh = byId("schedule-refresh");
  if (refresh) refresh.addEventListener("click", function () { loadScheduleView(); });
}
