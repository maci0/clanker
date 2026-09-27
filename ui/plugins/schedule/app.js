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

/* One row of the schedule list, the two lines that make up its head and foot,
   the cron chip, and one row of the fires log. Named rather than inlined so the
   head and the foot cannot drift apart.

   `group` + `data-[paused=true]` is how the struck-through cron survives the
   port: CSS could reach the child through the parent's attribute, and a utility
   cannot, so the parent carries the group and the child asks about it. */
var ENTRY_CLASS = "group mb-2 flex flex-col gap-2 rounded-plate border border-rule bg-surface px-4 py-3 data-[paused=true]:border-dashed";
var ROW_LINE_CLASS = "flex flex-wrap items-center gap-x-3 gap-y-2";
var CRON_CLASS = "rounded-plate-lg border border-rule bg-surface px-1.5 py-px text-sm group-data-[paused=true]:line-through";
/* 6rem/6rem/1fr is the log's own column template; on a phone the last column
   drops to a line of its own. */
var LOG_ROW_CLASS = "grid grid-cols-[6rem_6rem_1fr] items-baseline gap-2.5 data-[state=error]:text-danger max-[40rem]:grid-cols-[minmax(5rem,auto)_1fr]";

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

    var list = api.el("div");
    container.appendChild(list);

    container.appendChild(api.el("h3", "detail-head subsection-head", "Recent fires"));
    var logHost = api.el("ul", "m-0 flex list-none flex-col gap-1 p-0 text-sm");
    container.appendChild(logHost);

    const RELATIVE = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

    /* Fire durations and the "in 5m" line are read in the reader's own units
       and separators: a hardcoded "m"/"s" after toFixed renders "1,5s" in
       German, and a hand-rolled "in "/" ago" pair is English-only. Both go
       through Intl, which the app's own core/utils.js already relies on. */
    function fmtMs(ms) {
      if (typeof ms !== "number" || !isFinite(ms)) return "";
      var unit = ms < 1000 ? "millisecond" : "second";
      var v = ms < 1000 ? Math.round(ms) : Math.round(ms / 100) / 10;
      return new Intl.NumberFormat(undefined, {
        style: "unit", unit: unit, unitDisplay: "narrow", maximumFractionDigits: ms < 1000 ? 0 : 1
      }).format(v);
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
      var value, unit;
      if (n < 60) { value = n; unit = "second"; }
      else if (n < 3600) { value = Math.round(n / 60); unit = "minute"; }
      else if (n < 86400) { value = Math.round(n / 3600); unit = "hour"; }
      else { value = Math.round(n / 86400); unit = "day"; }
      return RELATIVE.format(ahead ? value : -value, unit);
    }

    function nextText(e) {
      if (!e.enabled) return "paused";
      if (!e.next_run) return "never: check the cron spec";
      var when = stampAt(e.next_run, e.tz_offset_minutes);
      if (e.next_run <= Math.floor(Date.now() / 1000)) return "due now · " + when;
      return when + " · " + relative(e.next_run);
    }

    function statusChip(e) {
      var chip = api.el("span", "meta data-[state=ok]:text-ok data-[state=error]:text-danger");
      if (!e.runs) { chip.textContent = "never run"; return chip; }
      var ok = e.last_status !== "error";
      chip.dataset.state = ok ? "ok" : "error";
      chip.textContent = (ok ? "ok" : "failed") + " · " + relative(e.last_run);
      chip.title = e.runs + (e.runs === 1 ? " run" : " runs") +
        (e.failures ? ", " + e.failures + " failed" : ", none failed");
      return chip;
    }

    function entryRow(e) {
      var row = api.el("article", ENTRY_CLASS);
      if (!e.enabled) row.dataset.paused = "true";

      var rowHead = api.el("div", ROW_LINE_CLASS);
      rowHead.appendChild(api.el("code", "text-sm text-fg-muted", e.id));
      var cron = api.el("code", CRON_CLASS, e.cron);
      cron.title = "Read at " + (e.tz_offset_minutes ? "offset " + e.tz_offset_minutes + " minutes" : "UTC");
      rowHead.appendChild(cron);
      rowHead.appendChild(statusChip(e));
      row.appendChild(rowHead);

      row.appendChild(api.el("p", "m-0 text-sm wrap-anywhere", e.task));

      var foot = api.el("div", ROW_LINE_CLASS);
      foot.appendChild(api.el("span", "meta mr-auto", nextText(e)));
      if (e.provider) {
        foot.appendChild(api.el("span", "meta", e.provider + (e.model ? " / " + e.model : "")));
      }
      var toggle = api.el("button", "secondary self-start", e.enabled ? "Pause" : "Resume");
      toggle.type = "button";
      toggle.setAttribute("aria-label", (e.enabled ? "Pause " : "Resume ") + e.id);
      toggle.disabled = state.busy === e.id;
      toggle.addEventListener("click", function () { setEnabled(e.id, !e.enabled); });
      foot.appendChild(toggle);
      row.appendChild(foot);
      return row;
    }

    function logRow(r) {
      var li = api.el("li", LOG_ROW_CLASS);
      li.dataset.state = r.ok ? "ok" : "error";
      li.appendChild(api.el("span", "meta", relative(r.ts)));
      li.appendChild(api.el("code", null, r.id));
      var bits = [r.ok ? "ok" : "failed", r.trigger];
      if (r.duration_ms) bits.push(fmtMs(r.duration_ms));
      if (r.skipped) bits.push(r.skipped + " window(s) skipped");
      if (r.err) bits.push(r.err);
      li.appendChild(api.el("span", "max-[40rem]:col-span-full", bits.join(" · ")));
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
