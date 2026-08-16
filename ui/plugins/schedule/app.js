/* schedule: what `clanker schedule` has been asked to run, when each
   entry fires next, how the last fire went, and a switch per entry.

   Read-and-toggle, matching GET /api/schedule and POST /api/schedule/<id>.
   Firing an entry is an agent run and this server answers one request per
   connection, so `run` and `run-due` stay with the system's own cron and the
   terminal. Adding stays there too: `add` has to reject a spec that never
   fires and say which of the spec and the task was wrong.

   Nothing here fires on its own either — see docs/prds/0009-schedule.md and
   ADR 0008. If the ledger is empty while entries look due, the answer is
   almost always that nothing is calling `run-due`, so the empty state says so. */

clanker.registerView({
  id: "schedule",
  title: "Schedule",
  group: "Set up",
  mount: function (container, api) {
    var state = { entries: [], log: [], busy: "", error: "" };

    var head = api.el("div", "section-head");
    head.appendChild(api.el("h2", null, "Schedule"));
    var refresh = api.el("button", "secondary", "Refresh");
    refresh.type = "button";
    head.appendChild(refresh);
    container.appendChild(head);

    var intro = api.el("p", "meta");
    intro.appendChild(document.createTextNode("What "));
    intro.appendChild(api.el("code", null, "clanker schedule"));
    intro.appendChild(document.createTextNode(" has been asked to run, and when each entry fires next. Times are each entry's own fixed UTC offset, never a DST-aware zone. Nothing fires from this page: entries run when the system's own cron calls "));
    intro.appendChild(api.el("code", null, "clanker schedule run-due"));
    intro.appendChild(document.createTextNode("."));
    container.appendChild(intro);

    var status = api.el("p", "meta");
    container.appendChild(status);

    var list = api.el("div", "schedule-list");
    container.appendChild(list);

    container.appendChild(api.el("h3", "detail-head subsection-head", "Recent fires"));
    var logHost = api.el("ul", "schedule-log");
    container.appendChild(logHost);

    function fmtMs(ms) {
      if (typeof ms !== "number" || !isFinite(ms)) return "";
      if (ms < 1000) return Math.round(ms) + "ms";
      if (ms < 60000) return (ms / 1000).toFixed(1) + "s";
      return Math.floor(ms / 60000) + "m " + Math.round((ms % 60000) / 1000) + "s";
    }

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

    function nextText(e) {
      if (!e.enabled) return "paused";
      if (!e.next_run) return "never: check the cron spec";
      var when = stampAt(e.next_run, e.tz_offset_minutes);
      if (e.next_run <= Math.floor(Date.now() / 1000)) return "due now · " + when;
      return when + " · " + relative(e.next_run);
    }

    function statusChip(e) {
      var chip = api.el("span", "meta schedule-status");
      if (!e.runs) { chip.textContent = "never run"; return chip; }
      var ok = e.last_status !== "error";
      chip.dataset.state = ok ? "ok" : "error";
      chip.textContent = (ok ? "ok" : "failed") + " · " + relative(e.last_run);
      chip.title = e.runs + (e.runs === 1 ? " run" : " runs") +
        (e.failures ? ", " + e.failures + " failed" : ", none failed");
      return chip;
    }

    function entryRow(e) {
      var row = api.el("article", "schedule-entry");
      if (!e.enabled) row.dataset.paused = "true";

      var rowHead = api.el("div", "schedule-entry-head");
      rowHead.appendChild(api.el("code", "schedule-id", e.id));
      var cron = api.el("code", "schedule-cron", e.cron);
      cron.title = "Read at " + (e.tz_offset_minutes ? "offset " + e.tz_offset_minutes + " minutes" : "UTC");
      rowHead.appendChild(cron);
      rowHead.appendChild(statusChip(e));
      row.appendChild(rowHead);

      row.appendChild(api.el("p", "schedule-task", e.task));

      var foot = api.el("div", "schedule-entry-foot");
      foot.appendChild(api.el("span", "meta schedule-next", nextText(e)));
      if (e.provider) {
        foot.appendChild(api.el("span", "meta", e.provider + (e.model ? " / " + e.model : "")));
      }
      var toggle = api.el("button", "secondary schedule-toggle", e.enabled ? "Pause" : "Resume");
      toggle.type = "button";
      toggle.setAttribute("aria-label", (e.enabled ? "Pause " : "Resume ") + e.id);
      toggle.disabled = state.busy === e.id;
      toggle.addEventListener("click", function () { setEnabled(e.id, !e.enabled); });
      foot.appendChild(toggle);
      row.appendChild(foot);
      return row;
    }

    function logRow(r) {
      var li = api.el("li", "schedule-log-row");
      li.dataset.state = r.ok ? "ok" : "error";
      li.appendChild(api.el("span", "meta", relative(r.ts)));
      li.appendChild(api.el("code", null, r.id));
      var bits = [r.ok ? "ok" : "failed", r.trigger];
      if (r.duration_ms) bits.push(fmtMs(r.duration_ms));
      if (r.skipped) bits.push(r.skipped + " window(s) skipped");
      if (r.err) bits.push(r.err);
      li.appendChild(api.el("span", null, bits.join(" · ")));
      return li;
    }

    function render() {
      list.textContent = "";
      if (!state.entries.length) {
        var empty = api.el("p", "run-empty");
        empty.appendChild(document.createTextNode("Nothing scheduled. Add one with"));
        empty.appendChild(document.createElement("br"));
        empty.appendChild(api.el("code", null, "clanker schedule add \"*/30 * * * *\" \"<task>\""));
        list.appendChild(empty);
      } else {
        state.entries.forEach(function (e) { list.appendChild(entryRow(e)); });
      }

      logHost.textContent = "";
      if (!state.log.length) {
        var none = api.el("li", "meta");
        none.textContent = state.entries.length
          ? "Nothing has fired yet. Entries only run when something calls `clanker schedule run-due`, usually a cron line, once a minute."
          : "Nothing has fired yet.";
        logHost.appendChild(none);
      } else {
        state.log.forEach(function (r) { logHost.appendChild(logRow(r)); });
      }

      if (state.error) {
        status.textContent = state.error;
        api.status(state.error);
        return;
      }
      var on = state.entries.filter(function (e) { return e.enabled; }).length;
      var msg = state.entries.length
        ? state.entries.length + (state.entries.length === 1 ? " entry" : " entries") + ", " + on + " active."
        : "No entries.";
      status.textContent = msg;
      api.status(msg);
    }

    function load() {
      status.textContent = "Loading schedule…";
      api.status("Loading schedule…");
      return api.getJSON("/api/schedule").then(function (data) {
        state.entries = (data && data.entries) || [];
        state.log = (data && data.log) || [];
        state.error = "";
        render();
        return data;
      }).catch(function (err) {
        var msg = "Could not load the schedule: " + err.message;
        status.textContent = msg;
        api.status(msg);
        list.textContent = "";
        var fail = api.el("p", "run-empty");
        fail.appendChild(document.createTextNode(msg + " "));
        var retry = api.el("button", "secondary", "Try again");
        retry.type = "button";
        retry.addEventListener("click", function () { load(); });
        fail.appendChild(retry);
        list.appendChild(fail);
      });
    }

    function setEnabled(id, on) {
      if (state.busy) return Promise.resolve(null);
      state.busy = id;
      state.error = "";
      render();
      status.textContent = (on ? "Resuming " : "Pausing ") + id + "…";
      api.status(status.textContent);
      return api.postJSON("/api/schedule/" + encodeURIComponent(id), { enabled: on }).then(function (data) {
        if (!data || !data.entry) throw new Error("the schedule did not come back");
        state.entries = state.entries.map(function (e) { return e.id === data.entry.id ? data.entry : e; });
        return data;
      }).catch(function (err) {
        state.error = "Could not update " + id + ": " + err.message;
        return null;
      }).then(function (out) {
        state.busy = "";
        render();
        return out;
      });
    }

    refresh.addEventListener("click", function () { load(); });
    this.reload = load;
    return load();
  },
  refresh: function () {
    if (this.reload) return this.reload();
  }
});
