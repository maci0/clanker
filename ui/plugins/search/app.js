/* search: find a saved conversation by what was said in it.

   The rail's filter box matches conversation titles, and titles are mostly
   auto-generated from the first line of the first task, so a conversation is
   findable by how it started and by nothing else. This searches the messages.

   Case-insensitive substring, matching GET /api/sessions/search. Deliberately
   not the fuzzy match the rail uses: fuzzy over whole transcripts matches
   nearly every conversation, and a search that always answers "all of them"
   is a search that answers nothing.

   Opening a hit switches to that conversation and lands on the turn that
   matched: the message index travels with the click. */

clanker.registerView({
  id: "search",
  title: "Search",
  group: "Work",
  mount: function (container, api) {
    var state = { query: "", hits: [], truncated: false, minLen: 3, searching: false, error: "" };
    var seq = 0;
    var timer = null;

    var head = api.el("div", "section-head");
    head.appendChild(api.el("h2", null, "Search"));
    container.appendChild(head);

    container.appendChild(api.el("p", "meta", "Find a saved conversation by what was said in it. The conversation list in the sidebar filters on titles; this reads the messages."));

    var tools = api.el("div", "transcript-tools");
    var label = api.el("label", null, "Search conversations");
    label.setAttribute("for", "search-q");
    var input = document.createElement("input");
    input.type = "search";
    input.id = "search-q";
    input.placeholder = "e.g. cron spec, provider refused, safeJoin…";
    input.autocomplete = "off";
    input.spellcheck = false;
    var btn = api.el("button", "primary", "Search conversations");
    btn.type = "button";
    btn.id = "search-go";
    tools.appendChild(label);
    tools.appendChild(input);
    tools.appendChild(btn);
    container.appendChild(tools);

    var status = api.el("p", "sr-only");
    status.id = "search-status";
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    container.appendChild(status);

    var list = api.el("div");
    list.id = "search-results";
    container.appendChild(list);

    function markInto(parent, text, needle) {
      var origFrom = 0;
      var foldFrom = 0;
      for (;;) {
        var hit = api.foldFind(text, needle, foldFrom);
        if (!hit) break;
        if (hit.start > origFrom) parent.appendChild(document.createTextNode(text.slice(origFrom, hit.start)));
        var m = document.createElement("mark");
        m.textContent = text.slice(hit.start, hit.end);
        parent.appendChild(m);
        origFrom = hit.end;
        foldFrom = hit.next;
      }
      if (origFrom < text.length) parent.appendChild(document.createTextNode(text.slice(origFrom)));
    }

    function hitRow(h) {
      var row = api.el("button", "secondary search-hit");
      row.type = "button";
      row.setAttribute("aria-label", "Open " + (h.title || h.id) + " at turn " + (h.turn + 1));

      var rowHead = api.el("div", "search-hit-head");
      rowHead.appendChild(api.el("span", "search-hit-title", h.title || h.id));
      rowHead.appendChild(api.el("span", "meta", api.fmt.time(h.updated)));
      if (h.archived) rowHead.appendChild(api.el("span", "meta", "archived"));
      row.appendChild(rowHead);

      var body = api.el("p", "search-hit-snippet");
      markInto(body, h.snippet || "", state.query);
      row.appendChild(body);

      row.appendChild(api.el("div", "meta search-hit-foot",
        h.role + " · turn " + (h.turn + 1) +
        (h.more ? " · " + h.more + " more match" + (h.more === 1 ? "" : "es") + " here" : "")));

      row.addEventListener("click", function () {
        api.openSession(h.id, { index: h.turn, query: state.query });
      });
      return row;
    }

    function setBusy(on) {
      var tooShort = input.value.trim().length < state.minLen;
      btn.disabled = on || tooShort;
      btn.title = on ? "Searching…" : (tooShort
        ? "Type at least " + state.minLen + " characters"
        : "Search conversations");
      input.setAttribute("aria-busy", on ? "true" : "false");
    }

    function render() {
      list.textContent = "";
      if (state.searching) {
        status.textContent = "Searching…";
        api.status("Searching…");
        list.setAttribute("aria-busy", "true");
        list.appendChild(api.el("p", "run-empty", "Searching…"));
        return;
      }
      list.removeAttribute("aria-busy");
      if (state.query.length < state.minLen) {
        list.appendChild(api.el("p", "run-empty",
          "Type at least " + state.minLen + " characters to search every saved conversation's messages."));
        status.textContent = "";
        return;
      }
      if (state.error) {
        var failed = api.el("p", "run-empty");
        failed.appendChild(document.createTextNode("Search failed: " + state.error + " "));
        var retry = api.el("button", "secondary", "Try again");
        retry.type = "button";
        retry.addEventListener("click", function () { runSearch(state.query); });
        failed.appendChild(retry);
        list.appendChild(failed);
        status.textContent = "Search failed: " + state.error;
        api.status(status.textContent);
        return;
      }
      if (!state.hits.length) {
        var none = api.el("p", "run-empty");
        none.appendChild(document.createTextNode("No conversation says “" + state.query + "”. Try another phrase, or filter titles in the sidebar. "));
        var clear = api.el("button", "secondary", "Clear search");
        clear.type = "button";
        clear.addEventListener("click", function () {
          input.value = "";
          input.focus();
          state.query = "";
          state.hits = [];
          state.error = "";
          state.searching = false;
          state.truncated = false;
          render();
        });
        none.appendChild(clear);
        list.appendChild(none);
        status.textContent = "No matches.";
        return;
      }
      state.hits.forEach(function (h) { list.appendChild(hitRow(h)); });
      var msg = state.hits.length +
        (state.hits.length === 1 ? " conversation" : " conversations") +
        (state.truncated ? " (showing the newest; narrow the search for more)" : "") + ".";
      status.textContent = msg;
      api.status(msg);
    }

    function runSearch(q) {
      state.query = (q || "").trim();
      if (state.query.length < state.minLen) {
        state.hits = [];
        state.truncated = false;
        state.searching = false;
        state.error = "";
        setBusy(false);
        render();
        return Promise.resolve(null);
      }
      var mine = ++seq;
      state.searching = true;
      state.error = "";
      setBusy(true);
      render();
      return api.getJSON("/api/sessions/search?q=" + encodeURIComponent(state.query))
        .then(function (data) {
          if (mine !== seq) return null;
          state.hits = (data && data.hits) || [];
          state.truncated = !!(data && data.truncated);
          state.error = "";
          state.searching = false;
          setBusy(false);
          render();
          return data;
        })
        .catch(function (err) {
          if (mine !== seq) return null;
          state.searching = false;
          state.hits = [];
          state.error = err.message;
          setBusy(false);
          render();
          return null;
        });
    }

    function load() {
      if (window._pendingSearchQuery) {
        input.value = window._pendingSearchQuery;
        window._pendingSearchQuery = null;
      }
      if (input.value.trim()) return runSearch(input.value);
      setBusy(false);
      render();
      return Promise.resolve(null);
    }

    btn.addEventListener("click", function () { runSearch(input.value); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); runSearch(input.value); }
    });
    input.addEventListener("input", function () {
      setBusy(false);
      if (timer) window.clearTimeout(timer);
      timer = window.setTimeout(function () { runSearch(input.value); }, 250);
    });

    this.reload = load;
    return load();
  },
  refresh: function () {
    if (this.reload) return this.reload();
  }
});
