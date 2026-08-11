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

    function draw(entries) {
      list.textContent = "";
      if (!entries.length) {
        list.appendChild(api.el("p", "run-empty", "Nothing recorded yet. Move a card, or write a line in a card's activity box."));
        return;
      }
      entries.forEach(function (e) {
        var row = api.el("p", "activity-row");
        row.appendChild(api.el("span", "activity-when", api.fmt.time(e.ts)));
        row.appendChild(api.el("span", "activity-who", e.who || "someone"));
        row.appendChild(api.el("span", "activity-what", e.what));
        var card = api.el("button", "activity-card", e.card);
        card.type = "button";
        card.title = "Open this card on the board";
        card.addEventListener("click", function () { api.showView("board"); });
        row.appendChild(card);
        list.appendChild(row);
      });
    }

    function load() {
      refresh.disabled = true;
      return api.getJSON("/api/board")
        .then(function (d) {
          var entries = [];
          ((d.board && d.board.cards) || []).forEach(function (c) {
            (c.log || []).forEach(function (e) {
              entries.push({ ts: e.ts, who: e.who, what: e.what, card: c.title });
            });
          });
          // Newest first: coming back to a board, the last thing that happened
          // is the thing you are looking for.
          entries.sort(function (a, b) { return (b.ts || 0) - (a.ts || 0); });
          draw(entries);
          api.status(entries.length + (entries.length === 1 ? " entry." : " entries."));
        })
        .catch(function (err) { api.status("Activity: " + err.message); })
        .then(function () { refresh.disabled = false; });
    }

    refresh.addEventListener("click", load);
    this.reload = load;
    return load();
  },
  refresh: function () {
    if (this.reload) this.reload();
  }
});
