/* office: every chatroom drawn as a room, with the people in it.
 *
 * Why this can be honest rather than decorative: since the board and the room
 * todo list became one thing, every card mutation *is* a message in that
 * room's log, carrying who did it and what they did. So an avatar walking to
 * the board and moving a sticker is driven by a real, attributed event. The
 * project this borrows its framing from watches transcripts and infers; we do
 * not have to infer anything.
 *
 * Everything here is already visible in the Board, Rooms and Goals views. The
 * canvas is aria-hidden and a text log beside it carries the same events, so
 * nothing is only available to someone who can see pixels.
 */

clanker.registerView({
  id: "office",
  title: "Office",
  group: "Watch",
  mount: function (container, api) {
    var van = api.van;
    var T = van.tags;

    var TILE = 16; // sprite grid; the whole scene is a multiple of this
    var status = van.state("");

    var canvas = document.createElement("canvas");
    canvas.className = "office-canvas";
    // Decorative and duplicative by design: the log below says the same thing.
    canvas.setAttribute("aria-hidden", "true");
    var ctx2d = canvas.getContext("2d");
    ctx2d.imageSmoothingEnabled = false;

    var logList = T.ul({ class: "office-log" });
    var head = T.div({ class: "section-head" },
      T.h2("Office"),
      T.span({ class: "meta" }, function () { return status.val; }));

    van.add(container, head, canvas,
      T.p({ class: "meta" }, "One office per room. An avatar walks to the board when an agent moves a card."),
      logList);

    /* ---------- deterministic layout ----------
       "Randomly generated" must not mean "different on every reload", or the
       floor is unreadable and nobody can learn their way around it. The room
       name seeds a small PRNG, so a room's office is always the same office. */

    function hashString(s) {
      var h = 2166136261;
      for (var i = 0; i < s.length; i++) {
        h ^= s.charCodeAt(i);
        h = (h * 16777619) >>> 0;
      }
      return h >>> 0;
    }

    function rng(seed) {
      var s = seed >>> 0;
      return function () {
        // xorshift32: tiny, deterministic, good enough to place furniture.
        s ^= s << 13; s >>>= 0;
        s ^= s >> 17;
        s ^= s << 5; s >>>= 0;
        return s / 4294967296;
      };
    }

    /* An office is a walled box with a door, a board on the top wall, a
       whiteboard beside it, and one desk per agent. Sizes vary with the room
       name and with how many people are in it, within bounds that keep every
       office legible next to its neighbours. */
    function layoutFor(room, agentCount) {
      var rand = rng(hashString(room));
      var w = 14 + Math.floor(rand() * 5);
      var desksNeeded = Math.max(1, agentCount);
      var rows = Math.ceil(desksNeeded / 3);
      var h = 9 + rows * 2 + Math.floor(rand() * 2);

      var desks = [];
      for (var i = 0; i < desksNeeded; i++) {
        var col = i % 3;
        var row = Math.floor(i / 3);
        desks.push({ x: 2 + col * 4, y: 5 + row * 3 });
      }
      return {
        room: room,
        w: w,
        h: h,
        door: { x: 1 + Math.floor(rand() * (w - 3)), y: h - 1 },
        board: { x: 2, y: 1, w: Math.max(6, w - 8), h: 3 },
        whiteboard: { x: w - 5, y: 1, w: 4, h: 3 },
        desks: desks
      };
    }

    /* ---------- state ---------- */

    var offices = [];      // { layout, cards, agents, cursor }
    var goals = [];
    var instanceName = "";
    var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    function agentColor(name) {
      // Stable per name, spread around the wheel. Saturation and lightness are
      // fixed so every avatar reads at the same weight on either theme.
      var hue = hashString(name) % 360;
      return "hsl(" + hue + ", 62%, 62%)";
    }

    function say(text) {
      var li = document.createElement("li");
      li.textContent = text;
      logList.insertBefore(li, logList.firstChild);
      while (logList.childNodes.length > 40) logList.removeChild(logList.lastChild);
    }

    /* ---------- drawing ----------
       Primitives for now: the sprite sheet lands in a later step, and drawing
       from theme tokens means the scene follows light/dark/mocha for free. */

    function cssVar(name, fallback) {
      var v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
      return v || fallback;
    }

    function drawOffice(o, ox, oy) {
      var L = o.layout;
      var wall = cssVar("--border", "#888");
      var floor = cssVar("--surface-2", "#eee");
      var ink = cssVar("--fg", "#111");
      var muted = cssVar("--fg-muted", "#666");

      ctx2d.fillStyle = floor;
      ctx2d.fillRect(ox, oy, L.w * TILE, L.h * TILE);
      ctx2d.strokeStyle = wall;
      ctx2d.lineWidth = 2;
      ctx2d.strokeRect(ox + 1, oy + 1, L.w * TILE - 2, L.h * TILE - 2);

      // Door: a gap in the wall, drawn as floor over the stroke.
      ctx2d.fillStyle = floor;
      ctx2d.fillRect(ox + L.door.x * TILE, oy + L.h * TILE - 3, TILE, 4);

      // Room name above its own office.
      ctx2d.fillStyle = muted;
      ctx2d.font = "10px ui-monospace, monospace";
      ctx2d.fillText(L.room, ox + 4, oy - 3);

      drawBoard(o, ox, oy);
      drawWhiteboard(o, ox, oy);

      // Desks.
      ctx2d.fillStyle = cssVar("--rule", "#ccc");
      L.desks.forEach(function (d) {
        ctx2d.fillRect(ox + d.x * TILE, oy + d.y * TILE, TILE * 2, TILE);
      });

      o.agents.forEach(function (a) { drawAgent(a, ox, oy, ink); });
    }

    function drawBoard(o, ox, oy) {
      var L = o.layout;
      var bx = ox + L.board.x * TILE;
      var by = oy + L.board.y * TILE;
      var bw = L.board.w * TILE;
      var bh = L.board.h * TILE;
      ctx2d.fillStyle = cssVar("--surface", "#fff");
      ctx2d.fillRect(bx, by, bw, bh);
      ctx2d.strokeStyle = cssVar("--border", "#888");
      ctx2d.lineWidth = 1;
      ctx2d.strokeRect(bx + 0.5, by + 0.5, bw - 1, bh - 1);

      // A post-it per card, in its column's band. The column decides the
      // horizontal band, so a card moving column visibly moves across the
      // board, which is the whole point of drawing it this way.
      var columns = ["backlog", "ready", "doing", "review", "done"];
      var bandW = bw / columns.length;
      var perColumn = {};
      o.cards.forEach(function (c) {
        var ci = columns.indexOf(c.column);
        if (ci < 0) ci = 0;
        perColumn[ci] = perColumn[ci] || 0;
        var n = perColumn[ci]++;
        var px = bx + ci * bandW + 3;
        var py = by + 4 + n * 9;
        if (py + 7 > by + bh) return; // board is full; the list view has them all
        ctx2d.fillStyle = c.assignee ? agentColor(c.assignee) : cssVar("--warn", "#e8c34a");
        ctx2d.fillRect(px, py, bandW - 6, 7);
      });
    }

    function drawWhiteboard(o, ox, oy) {
      var L = o.layout;
      var wx = ox + L.whiteboard.x * TILE;
      var wy = oy + L.whiteboard.y * TILE;
      ctx2d.fillStyle = cssVar("--paper", "#fff");
      ctx2d.fillRect(wx, wy, L.whiteboard.w * TILE, L.whiteboard.h * TILE);
      ctx2d.strokeStyle = cssVar("--border", "#888");
      ctx2d.strokeRect(wx + 0.5, wy + 0.5, L.whiteboard.w * TILE - 1, L.whiteboard.h * TILE - 1);
      // Goals as lines of "writing": the text itself is in the Goals view.
      ctx2d.fillStyle = cssVar("--fg-muted", "#666");
      goals.slice(0, 4).forEach(function (g, i) {
        var lineW = Math.min(L.whiteboard.w * TILE - 10, 8 + (hashString(g.objective || "") % 30));
        ctx2d.fillRect(wx + 4, wy + 6 + i * 7, lineW, 2);
      });
    }

    function drawAgent(a, ox, oy, ink) {
      var px = ox + a.x * TILE;
      var py = oy + a.y * TILE;
      ctx2d.fillStyle = agentColor(a.name);
      ctx2d.fillRect(px + 4, py + 2, 8, 12);  // body
      ctx2d.fillStyle = ink;
      ctx2d.fillRect(px + 6, py + 4, 2, 2);   // eyes
      ctx2d.fillRect(px + 10, py + 4, 2, 2);
      if (a.bubble) {
        ctx2d.fillStyle = cssVar("--surface", "#fff");
        ctx2d.fillRect(px + 12, py - 10, 46, 11);
        ctx2d.strokeStyle = cssVar("--border", "#888");
        ctx2d.strokeRect(px + 12.5, py - 9.5, 45, 10);
        ctx2d.fillStyle = cssVar("--fg", "#111");
        ctx2d.font = "8px ui-sans-serif, sans-serif";
        ctx2d.fillText(a.bubble.slice(0, 22), px + 15, py - 2);
      }
    }

    function draw() {
      var pad = 24;
      var x = pad, y = pad + 12, rowH = 0, maxW = 0;
      var placements = [];
      offices.forEach(function (o) {
        var w = o.layout.w * TILE;
        var h = o.layout.h * TILE;
        if (x + w > 1100 && x > pad) { x = pad; y += rowH + pad + 12; rowH = 0; }
        placements.push({ o: o, x: x, y: y });
        x += w + pad;
        rowH = Math.max(rowH, h);
        maxW = Math.max(maxW, x);
      });
      canvas.width = Math.max(320, maxW);
      canvas.height = y + rowH + pad;
      ctx2d.imageSmoothingEnabled = false;
      ctx2d.clearRect(0, 0, canvas.width, canvas.height);
      placements.forEach(function (p) { drawOffice(p.o, p.x, p.y); });
    }

    /* ---------- data ---------- */

    function seatAgents(o) {
      o.agents.forEach(function (a, i) {
        var d = o.layout.desks[i % o.layout.desks.length];
        a.x = d.x;
        a.y = d.y - 1;
      });
    }

    function load() {
      return api.getJSON("/api/status").then(function (s) {
        instanceName = (s.instance && s.instance.name) || "";
        return api.getJSON("/api/chat/rooms");
      }).then(function (r) {
        var rooms = (r.rooms || []).map(function (x) { return typeof x === "string" ? x : x.room; });
        return Promise.all(rooms.map(function (room) {
          return Promise.all([
            api.getJSON("/api/board?room=" + encodeURIComponent(room)).catch(function () { return { board: { cards: [] } }; }),
            api.getJSON("/api/chat/messages?room=" + encodeURIComponent(room)).catch(function () { return { messages: [] }; })
          ]).then(function (both) {
            var cards = (both[0].board && both[0].board.cards) || [];
            var msgs = both[1].messages || [];
            // Who is in this room: everyone who has said anything, plus us.
            var names = {};
            msgs.forEach(function (m) { if (m.from) names[m.from] = true; });
            if (instanceName) names[instanceName] = true;
            var agents = Object.keys(names).map(function (n) {
              return { name: n, x: 0, y: 0, bubble: null };
            });
            var cursor = 0;
            msgs.forEach(function (m) { if (m.ts > cursor) cursor = m.ts; });
            var o = { layout: layoutFor(room, agents.length), cards: cards, agents: agents, cursor: cursor, room: room };
            seatAgents(o);
            return o;
          });
        }));
      }).then(function (list) {
        offices = list;
        return api.getJSON("/api/goals").catch(function () { return { goals: [] }; });
      }).then(function (g) {
        goals = (g.goals || []).filter(function (x) { return x.status === "active"; });
        status.val = offices.length + (offices.length === 1 ? " room" : " rooms");
        draw();
      }).catch(function (err) {
        status.val = "could not load: " + err.message;
      });
    }

    /* ---------- events ----------
       A message starting with "@todo " is a card action: it names the actor,
       the verb and the card. Anything else is someone talking. Both come from
       the same poll, because both are just messages in the room. */

    var COLUMN_TITLES = {
      backlog: "Backlog", ready: "Ready", doing: "Doing", review: "Review", done: "Done"
    };

    function parseAction(text) {
      if (typeof text !== "string" || text.slice(0, 6) !== "@todo ") return null;
      try { return JSON.parse(text.slice(6)); } catch (e) { return null; }
    }

    function describe(actor, a) {
      switch (a.action) {
        case "add": return actor + " pinned up “" + (a.title || "a card") + "”";
        case "move": return actor + " moved a card to " + (COLUMN_TITLES[a.column] || a.column);
        case "close": return actor + " moved a card to Done";
        case "claim": return actor + " took a card";
        case "assign": return actor + (a.who ? " gave a card to " + a.who : " unassigned a card");
        case "delete": return actor + " took a card down";
        case "update": return actor + " changed a card";
        case "log": return actor + " noted work on a card";
        case "usage": return actor + " recorded cost on a card";
        default: return null;
      }
    }

    /* Walk to the board, do the thing, walk back. With reduced motion the
       walk is skipped and the effect applies at once, which is the same
       outcome without the movement. */
    function sendToBoard(o, agent, onArrive) {
      var target = { x: o.layout.board.x + 1, y: o.layout.board.y + o.layout.board.h };
      if (reduced) { onArrive(); return; }
      agent.walk = { to: target, home: { x: agent.x, y: agent.y }, phase: "out", onArrive: onArrive };
    }

    function stepAgents(dt) {
      var moved = false;
      offices.forEach(function (o) {
        o.agents.forEach(function (a) {
          if (!a.walk) return;
          moved = true;
          var dest = a.walk.phase === "out" ? a.walk.to : a.walk.home;
          var dx = dest.x - a.x, dy = dest.y - a.y;
          var dist = Math.sqrt(dx * dx + dy * dy);
          var speed = 6 * dt; // tiles per second
          if (dist <= speed) {
            a.x = dest.x; a.y = dest.y;
            if (a.walk.phase === "out") {
              a.walk.onArrive();
              a.walk.phase = "back";
            } else {
              a.walk = null;
            }
          } else {
            a.x += (dx / dist) * speed;
            a.y += (dy / dist) * speed;
          }
        });
      });
      return moved;
    }

    function agentIn(o, name) {
      for (var i = 0; i < o.agents.length; i++) if (o.agents[i].name === name) return o.agents[i];
      // Somebody who has not spoken in this room before: seat them now.
      var a = { name: name, x: 0, y: 0, bubble: null };
      o.agents.push(a);
      seatAgents(o);
      return a;
    }

    function applyMessage(o, m) {
      var action = parseAction(m.text);
      if (action) {
        var line = describe(m.from, action);
        if (!line) return;
        var actor = agentIn(o, m.from);
        say(o.room + ": " + line);
        sendToBoard(o, actor, function () {
          // Re-read the board rather than folding the action here: the server
          // already folds the log, and a second implementation of that would
          // drift from it.
          api.getJSON("/api/board?room=" + encodeURIComponent(o.room))
            .then(function (b) { o.cards = (b.board && b.board.cards) || o.cards; })
            .catch(function () {});
        });
        return;
      }
      var speaker = agentIn(o, m.from);
      say(o.room + ": " + m.from + " said “" + m.text.slice(0, 60) + "”");
      if (reduced) return;
      speaker.bubble = m.text;
      window.setTimeout(function () { speaker.bubble = null; }, 6000);
    }

    var polling = false;
    function poll() {
      if (polling || offices.length === 0) return Promise.resolve();
      polling = true;
      return Promise.all(offices.map(function (o) {
        return api.getJSON("/api/chat/messages?room=" + encodeURIComponent(o.room) + "&after=" + o.cursor)
          .then(function (r) {
            (r.messages || []).slice().sort(function (a, b) { return a.ts - b.ts; }).forEach(function (m) {
              if (m.ts <= o.cursor) return;
              o.cursor = m.ts;
              applyMessage(o, m);
            });
          })
          .catch(function () {});
      })).then(function () { polling = false; });
    }

    var last = 0;
    function frame(now) {
      var dt = last ? Math.min((now - last) / 1000, 0.1) : 0;
      last = now;
      if (stepAgents(dt) || dirty) { draw(); dirty = false; }
      raf = window.requestAnimationFrame(frame);
    }
    var dirty = true;
    var raf = window.requestAnimationFrame(frame);
    var timer = window.setInterval(function () { poll().then(function () { dirty = true; }); }, 3000);

    // The page keeps a mounted view around; stop the loop if it ever goes away.
    container.addEventListener("clanker:unmount", function () {
      window.cancelAnimationFrame(raf);
      window.clearInterval(timer);
    });

    load();
  }
});
