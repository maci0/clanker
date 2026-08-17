/* activity: everything the board records happening, merged into one timeline.

   The board answers "what is the state of this card". This answers "what has
   been happening", which is the question you ask when you come back to a board
   several clankers have been working on and want to know what moved.

   Two feeds, because neither is complete. A card's `log` array is written by
   one action only -- `log` -- so reading it alone showed nothing while cards
   were being added, moved and archived. The board room's messages carry every
   action, but only as far back as its history window. api.boardTimeline merges
   and dedupes them. */

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
        var empty = api.el("p", "run-empty", "Nothing recorded yet. Add or move a card, and it appears here. ");
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
      // The room is the feed that can be absent -- a fresh checkout has no
      // board room yet -- so a failure there degrades to the card logs rather
      // than emptying the view. Only the board failing is a failure.
      return Promise.all([
        api.getJSON("/api/board"),
        api.getJSON("/api/chat/messages?room=board&limit=500").catch(function () { return null; }),
      ])
        .then(function (both) {
          var d = both[0];
          var room = both[1];
          var entries = api.boardTimeline((d.board && d.board.cards) || [], (room && room.messages) || []);
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
