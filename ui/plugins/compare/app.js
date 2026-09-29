/* compare: past blind comparisons, one opened at a time, answers side by
   side in stored order, and a button per column that records the pick.

   The one property this file exists to protect: nothing here may say which
   model wrote which answer before a pick is recorded. `/api/compare` asks the
   tool for an un-revealed read, so the payload has no provider and no model
   in it at all. Once a pick is on record the tool reveals.

   Starting a comparison is not here. That is 2-8 concurrent model calls
   against a server that answers one request per connection, the same reason
   the Arena view links to `clanker arena` rather than starting a match.

   Reference: docs/prds/0006-webui.md, "Compare view". */

clanker.registerView({
  id: "compare",
  title: "Compare",
  group: "Watch",
  mount: function (container, api) {
    var state = { id: null, list: [], doc: null, picking: false };

    var head = api.el("div", "section-head");
    head.appendChild(api.el("h2", null, "Compare"));
    var actions = api.el("div", "toolbar-actions");
    var refresh = api.el("button", "secondary", "Refresh");
    refresh.type = "button";
    refresh.id = "compare-refresh";
    actions.appendChild(refresh);
    head.appendChild(actions);
    container.appendChild(head);

    var runs = api.el("div", "runs");
    var pickerSec = document.createElement("section");
    pickerSec.setAttribute("aria-labelledby", "compare-list-head");
    var listHead = api.el("h3", "sr-only", "Comparisons");
    listHead.id = "compare-list-head";
    var list = api.el("div", api.kit.recordRow.list);
    list.id = "compare-list";
    pickerSec.appendChild(listHead);
    pickerSec.appendChild(list);
    runs.appendChild(pickerSec);

    var prompt = api.el("p", "mb-1 mt-3 font-semibold");
    prompt.id = "compare-prompt";
    runs.appendChild(prompt);

    var status = api.el("p", "sr-only");
    status.id = "compare-status";
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    runs.appendChild(status);

    var answersSec = document.createElement("section");
    answersSec.setAttribute("aria-labelledby", "compare-answers-head");
    var answersHead = api.el("h3", "sr-only", "Answers, side by side");
    answersHead.id = "compare-answers-head";
    var answers = api.el("div", "grid grid-cols-[repeat(auto-fit,minmax(14rem,1fr))] items-start gap-3");
    answers.id = "compare-answers";
    answersSec.appendChild(answersHead);
    answersSec.appendChild(answers);
    runs.appendChild(answersSec);

    var verdict = api.el("div");
    verdict.id = "compare-verdict";
    runs.appendChild(verdict);

    var key = document.createElement("section");
    key.id = "compare-key";
      key.hidden = true;
    runs.appendChild(key);

    container.appendChild(runs);

    function showError(host, msg, retry) {
      if (!host) return;
      host.textContent = "";
      var fail = api.el("p", "run-empty");
      fail.appendChild(document.createTextNode(msg + " "));
      var again = api.el("button", "secondary", "Try again");
      again.type = "button";
      again.addEventListener("click", function () { retry(); });
      fail.appendChild(again);
      host.appendChild(fail);
    }

    function renderPicker(rows) {
      list.textContent = "";
      if (!rows.length) {
        var empty = api.el("p", "run-empty");
        empty.appendChild(document.createTextNode("No comparisons yet. Run one with "));
        empty.appendChild(api.el("code", null, "clanker compare \"<prompt>\" --with a --with b"));
        list.appendChild(empty);
        return;
      }
      rows.forEach(function (c) {
        var row = api.el("button", "secondary flex items-center gap-2.5 " + api.kit.recordRow.row);
        row.type = "button";
        row.setAttribute("aria-pressed", c.id === state.id ? "true" : "false");
        var q = api.el("span", "min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap " + api.kit.recordRow.name, c.prompt || c.id);
        q.title = c.prompt || c.id;
        row.appendChild(q);
        row.appendChild(api.el("span", "meta flex-none " + api.kit.recordRow.outcome, c.judged ? "judged" : "no verdict"));
        row.addEventListener("click", function () { fetchComparison(c.id); });
        list.appendChild(row);
      });
    }

    function answerColumn(doc, a, picked, winner) {
      var col = document.createElement("article");
      col.className = "group flex flex-col gap-1.5 rounded-plate border border-rule bg-surface-2 px-3 py-2.5 data-[picked=true]:border-accent";
      col.setAttribute("aria-labelledby", "compare-label-" + a.label);
      if (picked && picked === a.label) col.dataset.picked = "true";
      if (doc.revealed && winner && winner === a.label) col.dataset.winner = "true";

      var h = api.el("h4", "m-0 text-sm group-data-[winner=true]:text-ok", "Answer " + a.label);
      h.id = "compare-label-" + a.label;
      col.appendChild(h);

      col.appendChild(api.el("p", "meta", a.ok ? api.fmt.unit(a.ms, "millisecond") : ("no answer: " + (a.error || "unknown"))));

      var body = api.el("div", "text-sm whitespace-pre-wrap wrap-anywhere", a.ok ? (a.text || "") : "");
      col.appendChild(body);

      if (doc.revealed) {
        col.appendChild(api.el("p", "meta m-0",
          a.model ? (a.provider + " / " + a.model) : (a.provider || "")));
      }

      if (a.ok) {
        var pickBtn = api.el("button", "mt-auto self-start",
          picked === a.label ? ("Picked " + a.label) : ("Pick " + a.label));
        pickBtn.type = "button";
        pickBtn.disabled = !!picked;
        pickBtn.setAttribute("aria-label", picked === a.label
          ? ("Answer " + a.label + " is your pick")
          : ("Pick answer " + a.label));
        pickBtn.addEventListener("click", function () {
          if (picked || state.picking) return;
          api.confirm("Pick answer " + a.label + "? You cannot change this later.", {
            confirmLabel: "Pick " + a.label
          }).then(function (yes) { if (yes) recordPick(doc.id, a.label); });
        });
        col.appendChild(pickBtn);
      }
      return col;
    }

    function renderVerdict(host, doc, picked) {
      host.textContent = "";
      if (doc.verdict) {
        var line = "Judge picked " + doc.verdict.winner;
        if (doc.revealed && doc.verdict.provider) {
          line += " (" + doc.verdict.provider + (doc.verdict.model ? " / " + doc.verdict.model : "") + ")";
        }
        if (doc.verdict.reason) line += ": " + doc.verdict.reason;
        host.appendChild(api.el("p", "meta", line));
      }
      if (picked) {
        var mine = "Your pick: " + picked;
        if (doc.pick && doc.pick.provider) {
          mine += " · " + doc.pick.provider + (doc.pick.model ? " / " + doc.pick.model : "");
        }
        host.appendChild(api.el("p", "meta text-ok", mine));
      }
      if (doc.synthesis) {
        var card = api.el("div");
        card.appendChild(api.el("div", null, "Merged answer"));
        card.appendChild(api.el("div", null, doc.synthesis));
        host.appendChild(card);
      }
    }

    function renderKey(host, answerList) {
      host.textContent = "";
      host.hidden = false;
      host.appendChild(api.el("h3", null, "Key"));
      var dl = api.el("dl", "m-0 grid grid-cols-[auto_1fr] gap-x-2.5 gap-y-0.5 text-sm");
      answerList.forEach(function (a) {
        dl.appendChild(api.el("dt", "font-semibold", a.label));
        dl.appendChild(api.el("dd", "m-0 text-fg-muted", a.model ? (a.provider + " / " + a.model) : (a.provider || "")));
      });
      host.appendChild(dl);
    }

    function renderComparison(doc) {
      answers.textContent = "";
      verdict.textContent = "";
      key.textContent = "";
      key.hidden = true;
      prompt.textContent = doc ? (doc.prompt || "") : "";
      if (!doc) return;

      var cols = doc.answers || [];
      var picked = doc.pick ? doc.pick.label : "";
      var winner = doc.verdict ? doc.verdict.winner : "";
      answers.dataset.count = String(cols.length);
      cols.forEach(function (a) {
        answers.appendChild(answerColumn(doc, a, picked, winner));
      });

      renderVerdict(verdict, doc, picked);
      if (doc.revealed) renderKey(key, cols);

      status.textContent = doc.revealed
        ? (cols.length + " answers, revealed" + (picked ? ", you picked " + picked : "") + ".")
        : (cols.length + " answers, still blind. Read them, then pick one.");
      api.status(status.textContent);
    }

    function fetchComparison(id) {
      if (!id) return Promise.resolve(null);
      status.textContent = "Loading comparison " + id + "…";
      api.status(status.textContent);
      return api.getJSON("/api/compare/" + encodeURIComponent(id)).then(function (data) {
        if (!data || !data.ok) throw new Error((data && data.error) || "no such comparison");
        state.id = id;
        state.doc = data;
        try {
          var want = "#compare/" + encodeURIComponent(id);
          if (location.hash !== want) history.replaceState(null, "", want);
        } catch (_) {}
        renderComparison(data);
        renderPicker(state.list);
        return data;
      }).catch(function (err) {
        var msg = "Could not load comparison: " + err.message;
        status.textContent = msg;
        api.status(msg);
        prompt.textContent = "";
        verdict.textContent = "";
        key.textContent = "";
        key.hidden = true;
        showError(answers, msg, function () { return fetchComparison(id); });
        return null;
      });
    }

    function recordPick(id, label) {
      if (state.picking) return Promise.resolve(null);
      state.picking = true;
      status.textContent = "Recording pick " + label + "…";
      api.status(status.textContent);
      return api.postJSON("/api/compare/" + encodeURIComponent(id), { pick: label }).then(function (data) {
        if (!data || !data.ok) throw new Error((data && data.error) || "pick refused");
        state.doc = data;
        renderComparison(data);
        return data;
      }).catch(function (err) {
        status.textContent = "Could not record the pick: " + err.message;
        api.status(status.textContent);
        return null;
      }).then(function (out) {
        state.picking = false;
        return out;
      });
    }

    function load() {
      status.textContent = "Loading comparisons…";
      api.status(status.textContent);
      if (window._pendingCompareId) {
        state.id = window._pendingCompareId;
        window._pendingCompareId = null;
      }
      return api.getJSON("/api/compare").then(function (data) {
        var rows = (data && data.comparisons) || [];
        state.list = rows;
        renderPicker(rows);
        if (!rows.length) {
          status.textContent = "No comparisons yet. Run one with: clanker compare \"<prompt>\" --with a --with b";
          api.status(status.textContent);
          renderComparison(null);
          return null;
        }
        return fetchComparison(state.id || rows[0].id);
      }).catch(function (err) {
        var msg = "Could not load comparisons: " + err.message;
        status.textContent = msg;
        api.status(msg);
        showError(list, msg, load);
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
