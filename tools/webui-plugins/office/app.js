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

    var TILE = 32; // drawn size of one 16px source tile: 2x, so it is legible
    var dirty = true;
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
      var w = 16;
      var desksNeeded = Math.max(1, agentCount);
      var rows = Math.ceil(desksNeeded / 3);
      var h = 8 + rows * 2 + Math.floor(rand() * 2);

      var desks = [];
      for (var i = 0; i < desksNeeded; i++) {
        var col = i % 3;
        var row = Math.floor(i / 3);
        desks.push({ x: 2 + col * 5, y: 5 + row * 2 });
      }
      // Drawn once and reused: the bin has to keep clear of the doorway, and
      // rolling the die twice would put it somewhere else than the check.
      var doorX = 2 + Math.floor(rand() * (w - 5));
      var binX = doorX + 2 <= w - 3 ? doorX + 2 : doorX - 2;
      return {
        room: room,
        w: w,
        h: h,
        plants: [
          { x: w - 2, y: h - 2 },
          { x: 1, y: h - 2 }
        ],
        bin: { x: binX, y: h - 2 },
        door: { x: doorX, y: h - 1 },
        board: { x: 1, y: 1, w: w - 6, h: 3 },
        whiteboard: { x: w - 5, y: 1, w: 4, h: 3 },
        desks: desks
      };
    }

    /* ---------- state ---------- */

    var offices = [];      // { layout, cards, agents, cursor }
    var goals = [];
    /* The janitor. He is only in the room when there is something to sweep:
       /api/janitor reports orphaned staging copies and stale run graphs, and
       when it reports nothing he is not drawn at all. A mascot that mops a
       clean floor would be the one dishonest thing in this view. */
    var janitor = { present: false, bytes: 0, items: 0, x: 1, y: 1, dir: 1, quip: null, quipUntil: 0 };
    /* Short, apologetic, understated: the character says very little, and a
       mascot with a joke for every occasion would be a different one. The
       janitor.zig header records why these are not verbatim quotes. */
    var JANITOR_QUIPS = [
      "Sorry. I clean here.",
      "Is nothing. Small job.",
      "I am only cleaner.",
      "Hold my mop.",
      "You train? I clean. Same thing.",
      "Nobody clean this. Okay. I clean this.",
      "Is heavy? For you maybe.",
      "I do not lift. I tidy.",
      "First mop. Then we talk.",
      "Is fine. Floor is my gym.",
      "Somebody drop 300 megabyte. I say nothing.",
      "Okay. Finish. Where is next mess."
    ];

    var quipIdx = 0;
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

    /* ---------- sprites ----------
       Kenney's RPG Urban Pack, CC0; see ART.md for the licence and why this
       pack rather than the reference project's. One 17 KB sheet, 27x18 tiles
       of 16px, fetched only when this view opens. Until it loads (or if it
       fails) every draw falls back to the coloured rectangles below, so the
       floor is never blank and never blocks on the network. */
    var SHEET = new Image();
    var sheetReady = false;
    SHEET.onload = function () { sheetReady = true; dirty = true; };
    SHEET.src = "/webui/plugins/office/sprites.png";

    var TS = 16;
    // Tile picks, by grid coordinate on the sheet.
    var S_FLOOR = [11, 0];
    var S_WALL = [18, 2];
    var S_DESK = [4, 11];
    var S_BOARD = [13, 12];
    var S_WHITEBOARD = [9, 14];
    var S_JANITOR = [25, 6];
    var S_PLANT = [17, 9];
    var S_BIN = [10, 9];
    var S_AGENTS = [[23, 0], [24, 0], [25, 0], [26, 0], [23, 2], [24, 2], [25, 2], [26, 2]];

    function tile(t, dx, dy) {
      if (!sheetReady) return false;
      ctx2d.drawImage(SHEET, t[0] * TS, t[1] * TS, TS, TS, dx, dy, TILE, TILE);
      return true;
    }

    function spriteFor(name) {
      return S_AGENTS[hashString(name) % S_AGENTS.length];
    }

    /* ---------- drawing ----------
       Colours come from theme tokens where sprites do not, so the parts this
       still draws follow light, dark and the Catppuccin themes. */

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

      if (sheetReady) {
        for (var ty = 0; ty < L.h; ty++) {
          for (var tx = 0; tx < L.w; tx++) {
            var edge = tx === 0 || ty === 0 || tx === L.w - 1 || ty === L.h - 1;
            var isDoor = ty === L.h - 1 && tx === L.door.x;
            tile(edge && !isDoor ? S_WALL : S_FLOOR, ox + tx * TILE, oy + ty * TILE);
          }
        }
      } else {
        ctx2d.fillStyle = floor;
        ctx2d.fillRect(ox, oy, L.w * TILE, L.h * TILE);
        ctx2d.strokeStyle = wall;
        ctx2d.lineWidth = 2;
        ctx2d.strokeRect(ox + 1, oy + 1, L.w * TILE - 2, L.h * TILE - 2);
        ctx2d.fillStyle = floor;
        ctx2d.fillRect(ox + L.door.x * TILE, oy + L.h * TILE - 3, TILE, 4);
      }

      // Room name above its own office.
      ctx2d.fillStyle = muted;
      ctx2d.font = "12px ui-monospace, monospace";
      ctx2d.fillText(L.room, ox + 4, oy - 3);

      drawBoard(o, ox, oy);
      drawWhiteboard(o, ox, oy);

      (L.plants || []).forEach(function (pl) {
        tile(S_PLANT, ox + pl.x * TILE, oy + pl.y * TILE);
      });
      if (L.bin) tile(S_BIN, ox + L.bin.x * TILE, oy + L.bin.y * TILE);

      // Desks.
      L.desks.forEach(function (d) {
        var dx = ox + d.x * TILE;
        var dy = oy + d.y * TILE;
        ctx2d.fillStyle = "#8b5e34";
        ctx2d.fillRect(dx, dy + 3, TILE * 2, 7);
        ctx2d.fillStyle = "#6b4526";
        ctx2d.fillRect(dx + 1, dy + 10, 2, 4);
        ctx2d.fillRect(dx + TILE * 2 - 3, dy + 10, 2, 4);
      });

      o.agents.forEach(function (a) { drawAgent(a, ox, oy, ink, L.w); });
      if (janitor.present && o.isFirst) drawJanitor(ox, oy, ink);
    }

    /* Mop first, then the man: the handle leans the way he is walking. */
    function drawJanitor(ox, oy, ink) {
      var px = ox + janitor.x * TILE;
      var py = oy + janitor.y * TILE;
      ctx2d.strokeStyle = cssVar("--fg-muted", "#666");
      ctx2d.lineWidth = 1;
      ctx2d.beginPath();
      ctx2d.moveTo(px + 8 + janitor.dir * 5, py + 14);
      ctx2d.lineTo(px + 8 + janitor.dir * 2, py + 3);
      ctx2d.stroke();
      ctx2d.fillStyle = cssVar("--ok", "#7aa");
      ctx2d.fillRect(px + 4 + janitor.dir * 5, py + 13, 8, 3); // mop head
      if (!tile(S_JANITOR, px, py)) {
        ctx2d.fillStyle = cssVar("--warn", "#e8c34a");
        ctx2d.fillRect(px + 4, py + 2, 8, 12);
        ctx2d.fillStyle = ink;
        ctx2d.fillRect(px + 6, py + 4, 2, 2);
        ctx2d.fillRect(px + 10, py + 4, 2, 2);
      }
      if (janitor.quip && offices.length > 0) bubble(px, py, janitor.quip, ox, offices[0].layout.w);
    }

    function drawBoard(o, ox, oy) {
      var L = o.layout;
      var bx = ox + L.board.x * TILE;
      var by = oy + L.board.y * TILE;
      var bw = L.board.w * TILE;
      var bh = L.board.h * TILE;
      // Cork, drawn flat. The post-its have to be the loudest thing on it,
      // and a repeated sprite competes with them for the eye.
      ctx2d.fillStyle = "#8a6a44";
      ctx2d.fillRect(bx, by, bw, bh);
      ctx2d.fillStyle = "#6d5335";
      ctx2d.fillRect(bx, by, bw, 2);
      ctx2d.strokeStyle = "#4a3722";
      ctx2d.lineWidth = 2;
      ctx2d.strokeRect(bx + 1, by + 1, bw - 2, bh - 2);

      // A post-it per card, in its column's band. The column decides the
      // horizontal band, so a card moving column visibly moves across the
      // board, which is the whole point of drawing it this way.
      var columns = ["backlog", "ready", "doing", "review", "done"];
      var labels = ["BACKLOG", "READY", "DOING", "REVIEW", "DONE"];
      var bandW = bw / columns.length;

      // Divided into stages, the way the board it stands for is. Without the
      // ruled lines a note's column is a position you have to infer; with
      // them it is a place it is in.
      var headH = 13;
      ctx2d.fillStyle = "rgba(0,0,0,0.20)";
      ctx2d.fillRect(bx + 2, by + headH, bw - 4, 1);
      ctx2d.font = "9px ui-monospace, monospace";
      ctx2d.textAlign = "center";
      for (var li = 0; li < columns.length; li++) {
        if (li > 0) {
          ctx2d.fillStyle = "rgba(0,0,0,0.20)";
          ctx2d.fillRect(bx + li * bandW, by + 3, 1, bh - 6);
        }
        ctx2d.fillStyle = "rgba(255,255,255,0.72)";
        ctx2d.fillText(labels[li], bx + li * bandW + bandW / 2, by + 10);
      }
      ctx2d.textAlign = "left";
      var perColumn = {};
      o.cards.forEach(function (c) {
        var ci = columns.indexOf(c.column);
        if (ci < 0) ci = 0;
        perColumn[ci] = perColumn[ci] || 0;
        var n = perColumn[ci]++;
        var noteW = Math.min(bandW - 8, 26);
        var noteH = 20;
        var px = bx + ci * bandW + (bandW - noteW) / 2;
        var py = by + 20 + n * (noteH + 4);
        if (py + noteH > by + bh - 4) return; // board is full; the list has them all
        ctx2d.fillStyle = c.assignee ? agentColor(c.assignee) : "#f2d65c";
        ctx2d.fillRect(px, py, noteW, noteH);
        ctx2d.fillStyle = "rgba(0,0,0,0.18)";
        ctx2d.fillRect(px, py + noteH - 3, noteW, 3); // curl at the bottom
        // A pin, so a square of colour reads as something stuck to cork.
        ctx2d.fillStyle = "rgba(0,0,0,0.45)";
        ctx2d.fillRect(px + noteW / 2 - 1, py + 2, 3, 3);
      });
    }

    function drawWhiteboard(o, ox, oy) {
      var L = o.layout;
      var wx = ox + L.whiteboard.x * TILE;
      var wy = oy + L.whiteboard.y * TILE;
      ctx2d.fillStyle = "#f4f4ee";
      ctx2d.fillRect(wx, wy, L.whiteboard.w * TILE, L.whiteboard.h * TILE);
      ctx2d.strokeStyle = "#9aa0a6";
      ctx2d.lineWidth = 2;
      ctx2d.strokeRect(wx + 1, wy + 1, L.whiteboard.w * TILE - 2, L.whiteboard.h * TILE - 2);
      // Tray along the bottom, so it reads as a whiteboard and not a window.
      ctx2d.fillStyle = "#b9bfc5";
      ctx2d.fillRect(wx + 2, wy + L.whiteboard.h * TILE - 4, L.whiteboard.w * TILE - 4, 3);
      // Goals as lines of "writing": the text itself is in the Goals view.
      ctx2d.fillStyle = "#4a4a4a";
      ctx2d.font = "9px ui-monospace, monospace";
      ctx2d.fillText("GOALS", wx + 8, wy + 11);
      ctx2d.fillStyle = "#2f6ea8";
      goals.slice(0, 4).forEach(function (g, i) {
        var lineW = Math.min(L.whiteboard.w * TILE - 16, 20 + (hashString(g.objective || "") % 46));
        ctx2d.fillRect(wx + 8, wy + 20 + i * 12, lineW, 3);
      });
    }

    function drawAgent(a, ox, oy, ink, o_width) {
      var px = ox + a.x * TILE;
      var py = oy + a.y * TILE;
      if (!tile(spriteFor(a.name), px, py)) {
        ctx2d.fillStyle = agentColor(a.name);
        ctx2d.fillRect(px + 4, py + 2, 8, 12);
        ctx2d.fillStyle = ink;
        ctx2d.fillRect(px + 6, py + 4, 2, 2);
        ctx2d.fillRect(px + 10, py + 4, 2, 2);
      }
      if (a.bubble) bubble(px, py, a.bubble.slice(0, 30), ox, o_width);
    }

    /* Past halfway across its office a bubble opens to the left, so it never
       runs over the neighbouring room. */
    function bubble(px, py, text, ox, tilesWide) {
      ctx2d.font = "11px ui-sans-serif, sans-serif";
      var w = ctx2d.measureText(text).width + 10;
      var roomRight = ox + tilesWide * TILE;
      var bx = px + TILE * 0.75;
      if (bx + w > roomRight) bx = Math.max(ox + 4, px - w);
      ctx2d.fillStyle = "#fdfdf7";
      ctx2d.fillRect(bx, py - 18, w, 16);
      ctx2d.strokeStyle = "#5b5b5b";
      ctx2d.lineWidth = 1;
      ctx2d.strokeRect(bx + 0.5, py - 17.5, w - 1, 15);
      ctx2d.fillStyle = "#1a1a1a";
      ctx2d.fillText(text, bx + 5, py - 6);
    }

    function draw() {
      var pad = 24;
      var avail = Math.max(360, container.clientWidth - 8);
      var x = pad, y = pad + 16, rowH = 0, maxW = 0;
      var placements = [];
      offices.forEach(function (o) {
        var w = o.layout.w * TILE;
        var h = o.layout.h * TILE;
        if (x + w > avail && x > pad) { x = pad; y += rowH + pad + 20; rowH = 0; }
        placements.push({ o: o, x: x, y: y });
        x += w + pad;
        rowH = Math.max(rowH, h);
        maxW = Math.max(maxW, x);
      });
      canvas.width = Math.max(320, Math.min(avail, maxW));
      canvas.height = y + rowH + pad;
      // Displayed 1:1 with its backing store, so no fractional scaling.
      canvas.style.width = canvas.width + "px";
      canvas.style.height = canvas.height + "px";
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
        if (offices.length > 0) offices[0].isFirst = true;
        return api.getJSON("/api/janitor").catch(function () { return null; });
      }).then(function (jr) {
        if (jr && jr.ok) {
          var was = janitor.present;
          janitor.present = jr.items > 0;
          janitor.bytes = jr.bytes;
          janitor.items = jr.items;
          if (janitor.present && !was) {
            say("janitor: " + api.fmt.bytes(jr.bytes) + " to sweep up (clanker janitor --yes)");
          } else if (!janitor.present && was) {
            say("janitor: floor is clean, sitting down");
          }
        }
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

    function stepJanitor(dt, now) {
      if (!janitor.present || reduced || offices.length === 0) return false;
      var L = offices[0].layout;
      janitor.x += janitor.dir * 2.2 * dt;
      if (janitor.x > L.w - 2) { janitor.x = L.w - 2; janitor.dir = -1; }
      if (janitor.x < 1) { janitor.x = 1; janitor.dir = 1; }
      janitor.y = L.h - 2;
      if (now > janitor.quipUntil) {
        // A line every so often, cycling rather than random so he does not
        // say the same thing twice in a row.
        janitor.quip = JANITOR_QUIPS[quipIdx % JANITOR_QUIPS.length];
        quipIdx += 1;
        janitor.quipUntil = now + 9000;
      }
      return true;
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
      if (stepAgents(dt) | stepJanitor(dt, now) || dirty) { draw(); dirty = false; }
      raf = window.requestAnimationFrame(frame);
    }
    var raf = window.requestAnimationFrame(frame);
    var timer = window.setInterval(function () { poll().then(function () { dirty = true; }); }, 3000);
    var janitorTimer = window.setInterval(function () {
      api.getJSON("/api/janitor").then(function (jr) {
        if (!jr || !jr.ok) return;
        janitor.present = jr.items > 0;
        janitor.bytes = jr.bytes;
        janitor.items = jr.items;
        dirty = true;
      }).catch(function () {});
    }, 30000);

    // The page keeps a mounted view around; stop the loop if it ever goes away.
    container.addEventListener("clanker:unmount", function () {
      window.cancelAnimationFrame(raf);
      window.clearInterval(timer);
      window.clearInterval(janitorTimer);
    });

    window.addEventListener("resize", function () { dirty = true; });

    load();
  }
});
