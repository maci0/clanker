/* health: what the HTTP server is doing right now.
 *
 * `GET /api/metrics` has been served since the endpoint was added and nothing
 * in the browser ever read it. Everything it reports is invisible from the
 * page: how much traffic the server is taking, how much of it is failing, how
 * close it is to the connection limit, and how long it takes to answer.
 *
 * The saturation figure is the one worth having a view for. This server hands
 * each connection to a thread and answers one request per connection, so
 * `in_flight` against `connection_limit` is the difference between "busy" and
 * "your next request waits" — and it is what turns a poll in another view into
 * a dropped update. /health/ready reports the same condition as a 503, which
 * is a fine thing for a load balancer to read and a poor thing for a page: the
 * numbers here say how close it got, not just whether it arrived.
 *
 * The counters are monotonic totals, so a total is not a rate. Two samples are
 * differenced to get per-second figures, and until the second one arrives the
 * rates say so rather than showing a number that means something else. A
 * restart resets the counters; a total that goes backwards re-baselines instead
 * of drawing a negative rate.
 *
 * Nothing here is drawn on a canvas. The distribution is a real table with the
 * bars in a cell, so the numbers are the chart rather than a caption for it,
 * and a screen reader or a stylesheet-less page reads exactly what the bars
 * show. Colour is never the only encoding: the saturation state is a word.
 */

clanker.registerView({
  id: "health",
  title: "Health",
  group: "Watch",
  mount: function (container, api) {
    // Fractions of the connection limit at which the wording changes. Named
    // rather than inline so the table below and the tile agree.
    var BUSY_AT = 0.6;
    var SATURATED_AT = 1;

    /* When the error tile escalates past "something happened" to "something is
       wrong". A share alone is not enough: these are totals since start, so
       early on the denominator is tiny and one 404 for a path that does not
       exist reads as 1%, or 12%, or 50%. That is a client asking for something
       absent, not a server in trouble, and painting it the same as a server
       failing half its requests is how a panel earns being ignored. So the
       share has to clear a bar *and* there has to be enough of it to be a
       pattern; below that it stays a warning, with the counts beside it doing
       the talking. */
    var BAD_SHARE_PCT = 1;
    var BAD_ERRORS_MIN = 5;

    /* Bands are cut from the cumulative `le_*` buckets. The server loads each
       counter with its own atomic read, so a sample taken mid-request can have
       a bucket slightly ahead of `requests_total`; every subtraction is
       therefore clamped at zero rather than trusted to be ordered. */
    var BANDS = [
      { label: "up to 10ms", of: function (b) { return b.le_10; } },
      { label: "10ms to 100ms", of: function (b) { return b.le_100 - b.le_10; } },
      { label: "100ms to 1s", of: function (b) { return b.le_1000 - b.le_100; } },
      { label: "1s to 10s", of: function (b) { return b.le_10000 - b.le_1000; } },
      { label: "over 10s", of: function (b, total) { return total - b.le_10000; } }
    ];

    var prev = null;   // the previous sample: { at: ms, http: {...} }

    /* ------------------------------------------------------------- helpers */

    function num(v) { return typeof v === "number" && isFinite(v) ? v : 0; }
    function clamp0(v) { return v > 0 ? v : 0; }

    /// Per-second rate between two samples, and — when there isn't one — which
    /// of the two reasons applies. They are worth telling apart: "nothing to
    /// compare against yet" is a view that has just opened, while a counter
    /// that went backwards means the server restarted under us. Both show no
    /// rate; only one of them is news.
    function rateOf(before, after, beforeAt, afterAt) {
      if (before === null || beforeAt === null) return { rate: null, why: "first" };
      var seconds = (afterAt - beforeAt) / 1000;
      if (!(seconds > 0)) return { rate: null, why: "first" };
      if (after < before) return { rate: null, why: "reset" };
      return { rate: (after - before) / seconds, why: null };
    }

    /// The line under a rate. Always carries the running total, because that is
    /// the one number still true when the rate is not available.
    function rateNote(r, total) {
      if (r.why === "first") return "waiting for a second sample";
      if (r.why === "reset") return "counters reset, now " + total + " since start";
      return total + " since start";
    }

    function fmtRate(r) {
      if (r === null) return "—";
      if (r >= 10) return String(Math.round(r)) + "/s";
      return (Math.round(r * 10) / 10) + "/s";
    }

    function fmtMs(ms) {
      if (ms === null) return "—";
      if (ms >= 1000) return (Math.round(ms / 100) / 10) + "s";
      if (ms >= 10) return Math.round(ms) + "ms";
      return (Math.round(ms * 10) / 10) + "ms";
    }

    function pct(part, whole) {
      if (!(whole > 0)) return null;
      return (part / whole) * 100;
    }

    function fmtPct(p) {
      if (p === null) return "—";
      if (p === 0) return "0%";
      if (p < 0.1) return "<0.1%";
      if (p >= 10) return Math.round(p) + "%";
      return (Math.round(p * 10) / 10) + "%";
    }

    /// How alarming the error total is. Three states, and the middle one is
    /// where a handful of errors on a young counter belongs.
    function errorState(errors, sharePct) {
      if (errors === 0) return "good";
      if (sharePct !== null && sharePct >= BAD_SHARE_PCT && errors >= BAD_ERRORS_MIN) return "bad";
      return "warn";
    }

    /// The saturation wording. A state, not a colour: the word is what carries
    /// it, and the stylesheet only follows along.
    function loadState(inFlight, limit) {
      if (!(limit > 0)) return { key: "unknown", word: "unknown" };
      var share = inFlight / limit;
      if (share >= SATURATED_AT) return { key: "saturated", word: "saturated" };
      if (share >= BUSY_AT) return { key: "busy", word: "busy" };
      return { key: "ready", word: "ready" };
    }

    function bandCounts(http) {
      var b = {
        le_10: num(http.latency_buckets && http.latency_buckets.le_10),
        le_100: num(http.latency_buckets && http.latency_buckets.le_100),
        le_1000: num(http.latency_buckets && http.latency_buckets.le_1000),
        le_10000: num(http.latency_buckets && http.latency_buckets.le_10000)
      };
      var total = num(http.requests_total);
      return BANDS.map(function (band) {
        return { label: band.label, count: clamp0(band.of(b, total)) };
      });
    }

    /* ----------------------------------------------------------- structure */

    var head = api.el("div", "section-head");
    head.appendChild(api.el("h2", null, "Server health"));
    var state = api.el("span", "meta health-state");
    head.appendChild(state);
    var refresh = api.el("button", "secondary", "Refresh");
    refresh.type = "button";
    head.appendChild(refresh);
    container.appendChild(head);

    container.appendChild(api.el("p", "meta",
      "Read from /api/metrics and the live bus. Rates are measured between the last two samples, " +
      "so they describe recent traffic rather than the whole run."));

    var tiles = api.el("div", "health-tiles");
    container.appendChild(tiles);

    var distHead = api.el("h3", "health-sub", "Response times");
    container.appendChild(distHead);
    container.appendChild(api.el("p", "meta",
      "Every request the server has answered since it started, by how long it took."));
    var table = api.el("table", "health-bands");
    container.appendChild(table);

    /* ------------------------------------------------------------ painting */

    /// One stat tile: a label, a big number, and a quieter line under it. The
    /// note is text rather than a second colour, so a tile still reads when the
    /// state colour does not survive (forced colours, print, monochrome).
    function tile(label, value, note, stateKey) {
      var box = api.el("div", "health-tile");
      if (stateKey) box.setAttribute("data-state", stateKey);
      box.appendChild(api.el("span", "health-tile-label", label));
      box.appendChild(api.el("strong", "health-tile-value", value));
      box.appendChild(api.el("span", "health-tile-note", note));
      return box;
    }

    function drawTiles(http, llm, tools, schedule, jobs, at) {
      var total = num(http.requests_total);
      var errors = num(http.errors_total);
      var inFlight = num(http.in_flight);
      var limit = num(http.connection_limit);
      var llmTotal = num(llm && llm.requests_total);
      var llmErrors = num(llm && llm.errors_total);
      var llmRetries = num(llm && llm.retries_total);
      var toolsTotal = num(tools && tools.requests_total);
      var toolsErrors = num(tools && tools.errors_total);
      var schedTotal = num(schedule && schedule.fires_total);
      var schedErrors = num(schedule && schedule.errors_total);
      var llmTimeouts = num(llm && llm.timeouts_total);
      var jobStarts = num(jobs && jobs.starts_total);
      var jobDone = num(jobs && jobs.completions_total);
      var jobErrors = num(jobs && jobs.errors_total);
      var jobActive = num(jobs && jobs.active);

      var reqRate = rateOf(prev ? num(prev.http.requests_total) : null, total, prev ? prev.at : null, at);
      var errRate = rateOf(prev ? num(prev.http.errors_total) : null, errors, prev ? prev.at : null, at);
      var llmRate = rateOf(prev && prev.llm ? num(prev.llm.requests_total) : null, llmTotal, prev ? prev.at : null, at);
      var llmErrRate = rateOf(prev && prev.llm ? num(prev.llm.errors_total) : null, llmErrors, prev ? prev.at : null, at);
      var toolsRate = rateOf(prev && prev.tools ? num(prev.tools.requests_total) : null, toolsTotal, prev ? prev.at : null, at);
      var toolsErrRate = rateOf(prev && prev.tools ? num(prev.tools.errors_total) : null, toolsErrors, prev ? prev.at : null, at);
      var schedRate = rateOf(prev && prev.schedule ? num(prev.schedule.fires_total) : null, schedTotal, prev ? prev.at : null, at);
      var schedErrRate = rateOf(prev && prev.schedule ? num(prev.schedule.errors_total) : null, schedErrors, prev ? prev.at : null, at);
      var mean = total > 0 ? num(http.latency_ms_sum) / total : null;
      // Successes and failures alike, so this is "what a call costs", not
      // "what a good call costs".
      var llmMean = llmTotal > 0 ? num(llm.latency_ms_sum) / llmTotal : null;
      var errShare = pct(errors, total);
      var llmErrShare = pct(llmErrors, llmTotal);
      var toolsErrShare = pct(toolsErrors, toolsTotal);
      var schedErrShare = pct(schedErrors, schedTotal);
      var jobErrShare = pct(jobErrors, jobDone);
      var st = loadState(inFlight, limit);

      tiles.textContent = "";
      tiles.appendChild(tile(
        "Requests", fmtRate(reqRate.rate), rateNote(reqRate, total), null));
      tiles.appendChild(tile(
        "Errors", fmtRate(errRate.rate),
        errors + " of " + total + " (" + fmtPct(errShare) + ")",
        errorState(errors, errShare)));
      tiles.appendChild(tile(
        // in_flight counts the connection serving this very poll, so it never
        // reads zero from the browser. Said out loud rather than adjusted for.
        "In flight", inFlight + " of " + limit,
        st.word + ", this poll included",
        st.key === "ready" ? "good" : st.key === "busy" ? "warn" : "bad"));
      tiles.appendChild(tile(
        "Mean response", fmtMs(mean),
        total > 0 ? "over " + total + " requests" : "nothing served yet",
        null));
      tiles.appendChild(tile(
        "LLM calls", fmtRate(llmRate.rate),
        rateNote(llmRate, llmTotal) + (llmRetries ? ", " + llmRetries + " retried" : ""),
        null));
      tiles.appendChild(tile(
        "LLM errors", fmtRate(llmErrRate.rate),
        llmErrors + " of " + llmTotal + " (" + fmtPct(llmErrShare) + ")",
        errorState(llmErrors, llmErrShare)));
      tiles.appendChild(tile(
        "Mean LLM call", fmtMs(llmMean),
        llmTotal > 0 ? "over " + llmTotal + " calls" : "nothing called yet",
        null));
      tiles.appendChild(tile(
        // Apart from LLM errors on purpose: a lapsed deadline is a provider
        // that went quiet rather than one that refused, and retrying the same
        // endpoint is the one thing that cannot fix it.
        "LLM timeouts", String(llmTimeouts),
        llmTimeouts ? "provider went quiet" : "none",
        llmTimeouts ? "warn" : null));
      tiles.appendChild(tile(
        "Tool calls", fmtRate(toolsRate.rate),
        rateNote(toolsRate, toolsTotal), null));
      tiles.appendChild(tile(
        "Tool errors", fmtRate(toolsErrRate.rate),
        toolsErrors + " of " + toolsTotal + " (" + fmtPct(toolsErrShare) + ")",
        errorState(toolsErrors, toolsErrShare)));
      tiles.appendChild(tile(
        "Scheduled runs", fmtRate(schedRate.rate),
        rateNote(schedRate, schedTotal), null));
      tiles.appendChild(tile(
        "Schedule errors", fmtRate(schedErrRate.rate),
        schedErrors + " of " + schedTotal + " (" + fmtPct(schedErrShare) + ")",
        errorState(schedErrors, schedErrShare)));
      tiles.appendChild(tile(
        // A gauge, not a rate: background jobs are start-and-forget, so this
        // reading standing still while `starts_total` climbs is the signal
        // that something started and never finished.
        "Jobs running", String(jobActive),
        jobStarts + " started, " + jobDone + " finished", null));
      tiles.appendChild(tile(
        "Job errors", String(jobErrors),
        jobErrors + " of " + jobDone + " (" + fmtPct(jobErrShare) + ")",
        errorState(jobErrors, jobErrShare)));

      state.textContent = st.word === "unknown"
        ? "connection limit unknown"
        : inFlight + "/" + limit + " connections, " + st.word;
      state.setAttribute("data-state", st.key);
    }

    /* The distribution is a table and the bars live inside it. One hue, getting
       stronger as the band gets slower — an ordered magnitude, so a sequence
       rather than five separate identities. The bar is aria-hidden because the
       count and the share sit beside it in their own cells: the picture adds
       nothing a reader would otherwise miss. */
    function drawBands(http) {
      var counts = bandCounts(http);
      var sum = counts.reduce(function (a, b) { return a + b.count; }, 0);
      var peak = counts.reduce(function (a, b) { return b.count > a ? b.count : a; }, 0);

      table.textContent = "";
      var caption = api.el("caption", "health-bands-caption",
        sum > 0 ? sum + " requests measured" : "No requests measured yet");
      table.appendChild(caption);

      var thead = api.el("thead");
      var hrow = api.el("tr");
      ["Response time", "", "Requests", "Share"].forEach(function (label, i) {
        var th = api.el("th", null, label);
        th.setAttribute("scope", "col");
        if (i === 1) th.setAttribute("aria-label", "Relative size");
        hrow.appendChild(th);
      });
      thead.appendChild(hrow);
      table.appendChild(thead);

      var tbody = api.el("tbody");
      counts.forEach(function (band, i) {
        var tr = api.el("tr", "health-band");
        var th = api.el("th", "health-band-label", band.label);
        th.setAttribute("scope", "row");
        tr.appendChild(th);

        var barCell = api.el("td", "health-band-barcell");
        var track = api.el("div", "health-band-track");
        track.setAttribute("aria-hidden", "true");
        var bar = api.el("div", "health-band-bar");
        // Scaled against the largest band, so the shape of the distribution is
        // legible even when one band holds almost everything.
        bar.style.width = (peak > 0 ? (band.count / peak) * 100 : 0) + "%";
        bar.setAttribute("data-band", String(i));
        track.appendChild(bar);
        barCell.appendChild(track);
        tr.appendChild(barCell);

        tr.appendChild(api.el("td", "health-band-count", String(band.count)));
        tr.appendChild(api.el("td", "health-band-share", fmtPct(pct(band.count, sum))));
        tbody.appendChild(tr);
      });
      table.appendChild(tbody);
    }

    function drawFailure(message) {
      tiles.textContent = "";
      table.textContent = "";
      state.textContent = "";
      state.removeAttribute("data-state");
      var row = api.el("p", "run-empty", message + " ");
      var retry = api.el("button", "secondary", "Try again");
      retry.type = "button";
      retry.addEventListener("click", load);
      row.appendChild(retry);
      tiles.appendChild(row);
    }

    /* ------------------------------------------------------------- loading */

    /* The host never unmounts a view, it only toggles the panel's hidden
       attribute, so a poll left running would keep asking for a page nobody is
       looking at — and every one of those costs a connection another view's
       poll wanted. Gate on visibility, the way the office view does. */
    function viewHidden() {
      var view = container.closest(".view");
      return !!(view && view.hidden);
    }

    function applySample(d) {
      var http = (d && d.http) || null;
      if (!http) throw new Error("no http metrics in the response");
      var llm = (d && d.llm) || {};
      var tools = (d && d.tools) || {};
      var schedule = (d && d.schedule) || {};
      var jobs = (d && d.jobs) || {};
      var at = Date.now();
      drawTiles(http, llm, tools, schedule, jobs, at);
      drawBands(http);
      prev = { at: at, http: http, llm: llm, tools: tools, schedule: schedule, jobs: jobs };
      api.status("Health: " + num(http.requests_total) + " requests served, " +
        num(http.errors_total) + " errors, " +
        num(llm.requests_total) + " LLM calls, " +
        num(llm.errors_total) + " LLM errors, " +
        num(tools.requests_total) + " tool calls, " +
        num(schedule.fires_total) + " scheduled runs, " +
        num(jobs.active) + " background jobs running.");
      return http;
    }

    var inFlightLoad = false;
    function load() {
      if (inFlightLoad) return Promise.resolve(null);
      inFlightLoad = true;
      refresh.disabled = true;
      return api.getJSON("/api/metrics")
        .then(applySample)
        .catch(function (err) {
          // The previous sample is dropped: differencing across a gap of
          // unknown length would report a rate for a window that never
          // happened. The next successful read starts a fresh pair.
          prev = null;
          drawFailure("Could not read /api/metrics: " + err.message);
          api.status("Health: " + err.message);
          return null;
        })
        .then(function (out) {
          inFlightLoad = false;
          refresh.disabled = false;
          return out;
        });
    }

    refresh.addEventListener("click", function () { load(); });

    // Metrics ride the live bus (throttled to 1 Hz on the server). No poll:
    // a timer would spend a connection on a server that answers one request
    // per connection. Refresh still does a GET for a quiet server.
    api.onLive(function (ev) {
      if (!ev || ev.t !== "metrics" || !ev.http) return;
      if (viewHidden()) return;
      try { applySample(ev); } catch (e) {}
    });

    // Coming back to the view: the numbers on screen are as old as the moment
    // it was hidden, so read once immediately rather than waiting out a tick.
    // The stale sample is dropped for the same reason a failure drops it.
    function resume() {
      prev = null;
      load();
    }
    this.refresh = resume;
    var panel = container.closest(".view");
    if (panel) {
      new MutationObserver(function () { if (!panel.hidden) resume(); })
        .observe(panel, { attributes: true, attributeFilter: ["hidden"] });
    }

    return load();
  },
  refresh: function () {
    // Replaced by mount's own resume(); this stands in until then.
    return null;
  }
});
