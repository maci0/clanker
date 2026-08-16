/* activity: every log entry the board holds, merged into one timeline.

   The board answers "what is the state of this card". This answers "what has
   been happening", which is the question you ask when you come back to a board
   several clankers have been working on and want to know what moved. */

clanker.registerView({
  id: "activity",
  title: "Activity",
  group: "Watch",
  mount: function (container, api) {
    var head = api.el("div", "section-head");
    var h = api.el("h2", null, "Activity");
    var refresh = api.el("button", "secondary", "Refresh");
    refresh.type = "button";
    head.appendChild(h);
    head.appendChild(refresh);
    container.appendChild(head);

    var list = api.el("div", "activity-list");
    container.appendChild(list);

    /// A card that has never been given a title still has to be announceable,
    /// so the button falls back to naming the card by id rather than being an
    /// unlabelled target.
    function cardLabel(entry) {
      if (entry.card && entry.card.trim()) return entry.card;
      return entry.id ? "card " + entry.id : "an untitled card";
    }

    /// Open the card this entry belongs to. The kanban deep link is
    /// `#kanban/<id>` (`#board/<id>` still works). app.js waits for the
    /// view to load and opens that card.
    function openCard(entry) {
      if (!entry.id) { api.showView("kanban"); return; }
      var want = "#kanban/" + encodeURIComponent(entry.id);
      if (window.location.hash === want) { api.showView("kanban"); return; }
      window.location.hash = want;
    }

    function draw(entries) {
      list.textContent = "";
      if (!entries.length) {
        var empty = api.el("p", "run-empty", "Nothing recorded yet. Move a card, or write a line in a card's activity box. ");
        var go = api.el("button", "primary", "Open kanban");
        go.type = "button";
        go.addEventListener("click", function () { api.showView("kanban"); });
        empty.appendChild(go);
        list.appendChild(empty);
        return;
      }
      entries.forEach(function (e) {
        var row = api.el("p", "activity-row");
        row.appendChild(api.el("span", "activity-when", api.fmt.time(e.ts)));
        row.appendChild(api.el("span", "activity-who", e.who || "someone"));
        row.appendChild(api.el("span", "activity-what", e.what));
        var label = cardLabel(e);
        var card = api.el("button", "activity-card", label);
        card.type = "button";
        card.title = "Open this card on the board";
        card.setAttribute("aria-label", "Open " + label + " on the board");
        card.addEventListener("click", function () { openCard(e); });
        row.appendChild(card);
        list.appendChild(row);
      });
    }

    /// The board could not be read. Said in the list as well as in the status
    /// line, because leaving the previous timeline up made the view contradict
    /// itself: rows describing work while the status said the load had failed.
    function drawFailure(message) {
      list.textContent = "";
      var row = api.el("p", "run-empty", message + " ");
      var retry = api.el("button", "secondary", "Try again");
      retry.type = "button";
      retry.addEventListener("click", load);
      row.appendChild(retry);
      list.appendChild(row);
    }

    function load() {
      refresh.disabled = true;
      return api.getJSON("/api/board")
        .then(function (d) {
          var entries = [];
          ((d.board && d.board.cards) || []).forEach(function (c) {
            (c.log || []).forEach(function (e) {
              entries.push({ ts: e.ts, who: e.who, what: e.what, card: c.title, id: c.id });
            });
          });
          // Newest first: coming back to a board, the last thing that happened
          // is the thing you are looking for.
          entries.sort(function (a, b) { return (b.ts || 0) - (a.ts || 0); });
          draw(entries);
          api.status(entries.length + (entries.length === 1 ? " entry." : " entries."));
        })
        .catch(function (err) {
          drawFailure("Could not read the board: " + err.message);
          api.status("Activity: " + err.message);
        })
        .then(function () { refresh.disabled = false; });
    }

    refresh.addEventListener("click", load);
    this.reload = load;
    return load();
  },
  refresh: function () {
    if (this.reload) return this.reload();
    return null;
  }
});
