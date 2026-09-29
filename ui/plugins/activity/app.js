/* activity: everything the board records happening, merged into one timeline.

   The board answers "what is the state of this card". This answers "what has
   been happening", which is the question you ask when you come back to a board
   several clankers have been working on and want to know what moved.

   Two feeds, because neither is complete. A card's `log` array is written by
   one action only -- `log` -- so reading it alone showed nothing while cards
   were being added, moved and archived. The board room's messages carry every
   action, but only as far back as its history window. api.boardTimeline merges
   and dedupes them.

   Styled with Tailwind utilities (ui/app/tailwind.src.css), so this plugin
   ships no stylesheet: `p-3` is the cabinet's own --space-3 rung and the colour
   names are the tokens, not copies of them. ui/app/tailwind.test.mjs pins every
   utility used here against the generated sheet. */

/* One row of the timeline, and the card button inside it. Named rather than
   written inline so the two buttons that draw a row cannot drift apart. */
var ROW_CLASS = "m-0 flex flex-wrap items-baseline gap-3 border border-rule rounded-plate-sm bg-surface-2 px-3 py-2 font-mono text-sm";
/* min-h-8 is 2rem and min-h-11 is 2.75rem: 32px and the 44px touch target,
   which the two media blocks used to spell out separately. */
var CARD_CLASS = "min-h-8 cursor-pointer rounded-capsule border border-rule bg-transparent px-3 font-mono text-sm text-fg-muted hover:border-accent hover:text-accent pointer-coarse:min-h-11 max-[40rem]:min-h-11";

clanker.registerView({
  id: "activity",
  title: "Activity",
  group: "Watch",
  mount (container, api) {
    var head = api.el("div", "section-head");
    var h = api.el("h2", null, "Activity");
    var refresh = api.el("button", "secondary", "Refresh");
    refresh.type = "button";
    head.appendChild(h);
    head.appendChild(refresh);
    container.appendChild(head);

    var list = api.el("div", "mt-5 flex flex-col gap-2");
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
        var row = api.el("p", ROW_CLASS);
        row.appendChild(api.el("span", "basis-36 flex-none tabular-nums text-fg-muted", api.fmt.time(e.ts)));
        row.appendChild(api.el("span", "text-accent", e.who || "someone"));
        row.appendChild(api.el("span", "min-w-48 flex-1 text-fg wrap-anywhere", e.what));
        var label = cardLabel(e);
        var card = api.el("button", CARD_CLASS, label);
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
          api.status(api.fmt.plural(entries.length, { one: "entry.", other: "entries." }));
        })
        .catch(function (err) {
          drawFailure("Could not read the board: " + err.message);
          api.status("Activity: " + err.message);
        })
        .then(function () { refresh.disabled = false; });
    }

    refresh.addEventListener("click", load);
    this.reload = load;

    /* Live updates: every board action lands in the board room, and the live
       bus carries each room message as a `{t:"chat", room:…}` event, so the
       timeline can follow the board instead of waiting for Refresh. Idle
       while hidden — `mount` gets the inner <section>, the host toggles
       `hidden` on the enclosing `.view` panel, so ask the panel the way mesh
       and office do — and re-entry is covered by the refresh hook. A load
       already in flight (refresh is disabled for exactly that window) is
       reporting the state this event announced, so it is not doubled. */
    function viewHidden() {
      var view = container.closest ? container.closest(".view") : null;
      return !!(view && view.hidden);
    }
    api.onLive(function (ev) {
      if (!ev || viewHidden() || refresh.disabled) return;
      if (ev.t === "chat" && ev.room === "board") load();
    });

    return load();
  },
  refresh () {
    if (this.reload) return this.reload();
    return null;
  }
});
