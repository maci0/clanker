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

    /* Sleep + alarm: an agent with no message for SLEEP_AFTER seconds dozes
       at its desk (zzZ). With the alarm armed, a room with sleepers gets its
       wall clock rung at most once per RING_COOLDOWN, and the ring is a real
       room message (fanned out to peers like any other), not just pixels. */
    var SLEEP_AFTER = 300;
    var RING_COOLDOWN = 600;
    var RING_MS = 4000;
    var alarmOn = van.state(localStorage.getItem("clanker-office-alarm") === "on");

    function nowSec() { return Math.floor(Date.now() / 1000); }
    function asleep(a) { return !a.walk && nowSec() - (a.lastSeen || 0) > SLEEP_AFTER; }

    var canvas = document.createElement("canvas");
    canvas.className = "office-canvas";
    // Decorative and duplicative by design: the log below says the same thing.
    canvas.setAttribute("aria-hidden", "true");
    var ctx2d = canvas.getContext("2d");
    ctx2d.imageSmoothingEnabled = false;

    var logList = T.ul({ class: "office-log" });
    var head = T.div({ class: "section-head" },
      T.h2("Office"),
      T.span({ class: "meta" }, function () { return status.val; }),
      T.label({ class: "meta office-alarm" },
        T.input({
          type: "checkbox",
          checked: alarmOn.val ? "" : null,
          onchange: function (e) {
            alarmOn.val = !!e.target.checked;
            localStorage.setItem("clanker-office-alarm", alarmOn.val ? "on" : "off");
            dirty = true;
          },
        }),
        " alarm clock"));

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
        shelf: { x: w - 2, y: 5 },
        cooler: { x: w - 2, y: 7 },
        sofa: { x: 2 + Math.floor(rand() * 2), y: h - 3 },
        pictures: [
          { x: 4 + Math.floor(rand() * 3), y: 4 },
          { x: 9 + Math.floor(rand() * 3), y: 4 }
        ],
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

    /* Characters come from a second CC0 pack, because neither pack has both
       halves: this one has animated people and no office, Kenney's has the
       office and only static figures. One 16px row per character, twelve
       columns: four walk frames for each of down, up and left. Right is left
       mirrored (the two side columns are pixel-identical on the source sheet),
       so it costs no columns. Row CH_JANITOR is his; the rest are avatars. */
    var CHARS = new Image();
    var charsReady = false;
    var CH = 16, CH_FRAMES = 4, CH_AGENTS = 8, CH_JANITOR = 8;
    var DIR_DOWN = 0, DIR_UP = 1, DIR_LEFT = 2, DIR_RIGHT = 3;
    CHARS.onload = function () { charsReady = true; dirty = true; };
    CHARS.src = "/webui/plugins/office/characters.png";

    var TS = 16;
    // Tile picks, by grid coordinate on the sheet. The sheet is this
    // repository's own pixel art, generated by gen_art.py in this directory;
    // the coordinates below are that script's TILE order, a 6x2 grid.
    var S_FLOOR = [0, 0];
    var S_FLOOR2 = [6, 0];        // darker course; the room checkers the two
    var S_WALL = [1, 0];
    var S_PLANT = [2, 0];
    var S_BIN = [3, 0];
    var S_SHELF = [4, 0];
    var S_COOLER = [5, 0];
    var S_SOFA = [[0, 1], [1, 1]];
    var S_DESK = [2, 1];          // desk with its terminal; S_CHAIR pulls up to it
    var S_CHAIR = [3, 1];
    var S_PICTURE = [4, 1];
    var S_DOOR = [5, 1];

    function tile(t, dx, dy) {
      if (!sheetReady) return false;
      ctx2d.drawImage(SHEET, t[0] * TS, t[1] * TS, TS, TS, dx, dy, TILE, TILE);
      return true;
    }

    /* Which way a mover points. Vertical only wins on a clear vertical run,
       so an avatar crossing the room to the board keeps facing the way it
       travels instead of flickering between axes on a near-diagonal. */
    function facingOf(dx, dy, previous) {
      if (Math.abs(dx) < 0.01 && Math.abs(dy) < 0.01) return previous || DIR_DOWN;
      if (Math.abs(dy) > Math.abs(dx)) return dy > 0 ? DIR_DOWN : DIR_UP;
      return dx > 0 ? DIR_RIGHT : DIR_LEFT;
    }

    /* Draws one character filling the tile at (dx, dy). `phase` advances only
       while moving, so a standing avatar holds its first frame instead of
       marching on the spot. False before the sheet loads, which is the
       caller's cue to fall back to a drawn figure. */
    function character(row, dx, dy, moving, phase, facing) {
      if (!charsReady) return false;
      var frame = moving ? Math.floor(phase * 8) % CH_FRAMES : 0;
      var col = (facing === DIR_RIGHT ? DIR_LEFT : facing) * CH_FRAMES + frame;
      if (facing !== DIR_RIGHT) {
        ctx2d.drawImage(CHARS, col * CH, row * CH, CH, CH, dx, dy, TILE, TILE);
        return true;
      }
      ctx2d.save();
      ctx2d.translate(dx + TILE, dy);
      ctx2d.scale(-1, 1);
      ctx2d.drawImage(CHARS, col * CH, row * CH, CH, CH, 0, 0, TILE, TILE);
      ctx2d.restore();
      return true;
    }

    function charRow(name) {
      return hashString(name) % CH_AGENTS;
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
            var floor_t = (tx + ty) % 2 ? S_FLOOR2 : S_FLOOR;
            tile(edge && !isDoor ? S_WALL : floor_t, ox + tx * TILE, oy + ty * TILE);
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
      if (alarmOn.val) drawAlarmClock(o, ox, oy);

      (L.plants || []).forEach(function (pl) {
        tile(S_PLANT, ox + pl.x * TILE, oy + pl.y * TILE);
      });
      if (L.bin) tile(S_BIN, ox + L.bin.x * TILE, oy + L.bin.y * TILE);
      if (L.shelf) tile(S_SHELF, ox + L.shelf.x * TILE, oy + L.shelf.y * TILE);
      if (L.cooler) tile(S_COOLER, ox + L.cooler.x * TILE, oy + L.cooler.y * TILE);
      if (L.sofa) {
        S_SOFA.forEach(function (s, i) {
          tile(s, ox + (L.sofa.x + i) * TILE, oy + L.sofa.y * TILE);
        });
      }
      // Pictures hang on the wall the board does not occupy.
      (L.pictures || []).forEach(function (pic) {
        tile(S_PICTURE, ox + pic.x * TILE, oy + pic.y * TILE);
      });
      // A door in the doorway, rather than a gap in the bricks.
      tile(S_DOOR, ox + L.door.x * TILE, oy + L.door.y * TILE);

      // Desks.
      L.desks.forEach(function (d) {
        var dx = ox + d.x * TILE;
        var dy = oy + d.y * TILE;
        // A desk is a table with a chair pulled up to it: two tiles that read
        // as one workstation, which a doubled table never did.
        if (!tile(S_DESK, dx, dy)) {
          ctx2d.fillStyle = "#8b5e34";
          ctx2d.fillRect(dx, dy + 3, TILE * 2, 7);
        } else {
          tile(S_CHAIR, dx + TILE, dy);
        }
      });

      o.agents.forEach(function (a) { drawAgent(a, ox, oy, ink, L.w); });
      if (janitor.present && o.isFirst) drawJanitor(ox, oy, ink);
    }

    /* The man, then his mop: the handle leans the way he is walking, and it
       has to sit in front of him or it reads as a stick growing out of his
       back. Sized off the sprite, not the tile, so it stays in his hands. */
    function drawJanitor(ox, oy, ink) {
      var px = ox + janitor.x * TILE;
      var py = oy + janitor.y * TILE;
      janitor.phase = (janitor.phase || 0) + 0.016;
      // He sweeps a horizontal beat, so his facing is his direction of travel.
      var drawn = character(CH_JANITOR, px, py, true, janitor.phase,
        janitor.dir > 0 ? DIR_RIGHT : DIR_LEFT);
      if (!drawn) {
        ctx2d.fillStyle = cssVar("--warn", "#e8c34a");
        ctx2d.fillRect(px + 4, py + 2, 8, 12);
        ctx2d.fillStyle = ink;
        ctx2d.fillRect(px + 6, py + 4, 2, 2);
        ctx2d.fillRect(px + 10, py + 4, 2, 2);
      }
      var cx = drawn ? px + TILE / 2 : px + 8;  // centre of whichever figure ran
      var foot = drawn ? py + TILE - 2 : py + 14;
      var hand = drawn ? py + TILE / 2 : py + 3;
      // Stepped in 2px blocks rather than stroked: a smooth antialiased
      // diagonal is the one thing on this floor that is not pixel art. Held
      // out past the sprite's shoulder, because a handle crossing his torso
      // is a dark line on dark cloth and disappears.
      ctx2d.fillStyle = cssVar("--fg-muted", "#666");
      var x0 = cx + janitor.dir * 15, x1 = cx + janitor.dir * 9;
      for (var s = 0; s <= 12; s++) {
        var t = s / 12;
        ctx2d.fillRect(
          Math.round((x0 + (x1 - x0) * t) / 2) * 2,
          Math.round((foot + (hand - foot) * t) / 2) * 2,
          2, 2);
      }
      ctx2d.fillStyle = cssVar("--ok", "#7aa");
      ctx2d.fillRect(cx + janitor.dir * 15 - 4, foot - 2, 9, 4); // mop head
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
      var walking = !!a.walk;
      if (character(charRow(a.name), px, py, walking, a.phase || 0, a.facing || DIR_DOWN)) {
        // drawn
      } else {
        ctx2d.fillStyle = agentColor(a.name);
        ctx2d.fillRect(px + 4, py + 2, 8, 12);
        ctx2d.fillStyle = ink;
        ctx2d.fillRect(px + 6, py + 4, 2, 2);
        ctx2d.fillRect(px + 10, py + 4, 2, 2);
      }
      if (a.bubble) bubble(px, py, a.bubble.slice(0, 30), ox, o_width);
      else if (asleep(a)) drawZzz(px, py);
    }

    /* Three z's drifting up from a dozing head. With reduced motion they sit
       still: the state still reads, only the drift is skipped. */
    function drawZzz(px, py) {
      ctx2d.font = "bold 13px ui-monospace, monospace";
      var t = reduced ? 0 : performance.now() / 1600;
      for (var i = 0; i < 3; i++) {
        var ph = reduced ? i * 0.3 : (t + i * 0.33) % 1;
        var ch = i === 2 ? "Z" : "z";
        var zx = px + TILE - 6 + ph * 8;
        var zy = py - 6 - ph * 16;
        var alpha = 1 - ph * 0.45;
        // Drawn twice, shadow then face: the drift crosses the dark board
        // graphic, where a single unbacked glyph disappears entirely.
        ctx2d.fillStyle = "rgba(10,14,28," + alpha.toFixed(2) + ")";
        ctx2d.fillText(ch, zx + 1, zy + 1);
        ctx2d.fillStyle = "rgba(214,226,255," + alpha.toFixed(2) + ")";
        ctx2d.fillText(ch, zx, zy);
      }
    }

    /* A little red wall clock, drawn only while the alarm is armed. When a
       ring is live it judders and shouts; otherwise its hands just tell the
       actual time, which is what wall clocks are for. */
    function drawAlarmClock(o, ox, oy) {
      var L = o.layout;
      var cx = ox + (L.w - 1.5) * TILE;
      var cy = oy + 0.55 * TILE;
      var ringing = performance.now() < o.ringUntil;
      var jx = ringing && !reduced ? Math.round(Math.sin(performance.now() / 30) * 2) : 0;
      ctx2d.fillStyle = "#c94f4f";
      ctx2d.fillRect(cx + jx - 7, cy - 9, 4, 3); // bells
      ctx2d.fillRect(cx + jx + 3, cy - 9, 4, 3);
      ctx2d.beginPath();
      ctx2d.arc(cx + jx, cy, 7, 0, Math.PI * 2);
      ctx2d.fill();
      ctx2d.fillStyle = "#f4f4ee";
      ctx2d.beginPath();
      ctx2d.arc(cx + jx, cy, 5, 0, Math.PI * 2);
      ctx2d.fill();
      ctx2d.strokeStyle = "#1a1a1a";
      ctx2d.lineWidth = 1;
      var d = new Date();
      var mins = d.getMinutes() / 60 * Math.PI * 2 - Math.PI / 2;
      var hrs = ((d.getHours() % 12) + d.getMinutes() / 60) / 12 * Math.PI * 2 - Math.PI / 2;
      ctx2d.beginPath();
      ctx2d.moveTo(cx + jx, cy);
      ctx2d.lineTo(cx + jx + Math.cos(mins) * 4, cy + Math.sin(mins) * 4);
      ctx2d.moveTo(cx + jx, cy);
      ctx2d.lineTo(cx + jx + Math.cos(hrs) * 2.5, cy + Math.sin(hrs) * 2.5);
      ctx2d.stroke();
      if (ringing) {
        ctx2d.fillStyle = "#c94f4f";
        ctx2d.font = "bold 10px ui-sans-serif, sans-serif";
        ctx2d.fillText("RRRING", cx - 18, cy - 13);
      }
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
            // The newest message per speaker doubles as their awake-ness.
            var names = {};
            msgs.forEach(function (m) { if (m.from) names[m.from] = Math.max(names[m.from] || 0, m.ts || 0); });
            if (instanceName && !(instanceName in names)) names[instanceName] = 0;
            var agents = Object.keys(names).map(function (n) {
              return { name: n, x: 0, y: 0, bubble: null, lastSeen: names[n] };
            });
            var cursor = 0;
            msgs.forEach(function (m) { if (m.ts > cursor) cursor = m.ts; });
            var o = { layout: layoutFor(room, agents.length), cards: cards, agents: agents, cursor: cursor, room: room, ringAt: 0, ringUntil: 0 };
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
            a.phase = (a.phase || 0) + dt;
            a.facing = facingOf(dx, dy, a.facing);
          }
        });
      });
      return moved;
    }

    function agentIn(o, name) {
      for (var i = 0; i < o.agents.length; i++) if (o.agents[i].name === name) return o.agents[i];
      // Somebody who has not spoken in this room before: seat them now.
      var a = { name: name, x: 0, y: 0, bubble: null, lastSeen: 0 };
      o.agents.push(a);
      seatAgents(o);
      return a;
    }

    function applyMessage(o, m) {
      if (m.from) {
        var who = agentIn(o, m.from);
        if ((m.ts || 0) > (who.lastSeen || 0)) who.lastSeen = m.ts;
      }
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

    /* Sleep animation needs frames while anyone is dozing or a ring is
       live; with reduced motion both are drawn static, so no frames. */
    function stepSleep(now) {
      if (reduced) return false;
      var animate = false;
      offices.forEach(function (o) {
        if (now < o.ringUntil) { animate = true; return; }
        o.agents.forEach(function (a) { if (asleep(a)) animate = true; });
      });
      return animate;
    }

    /* The actual wake-up call. One ring per room per cooldown, and only for
       rooms with someone visibly asleep. The message goes through the normal
       room send, so subscribed peers receive it like anything else said here.
       Our own avatar can doze but is never a ring target: the call is sent AS
       this instance, so ringing for ourselves would wake nobody and refresh
       our own lastSeen, looping ring -> doze -> ring forever. */
    function checkAlarm() {
      if (!alarmOn.val) return;
      var now = nowSec();
      offices.forEach(function (o) {
        var sleepers = o.agents.filter(function (a) { return a.name !== instanceName && asleep(a); })
          .map(function (a) { return a.name; });
        if (sleepers.length === 0) return;
        if (now - (o.ringAt || 0) < RING_COOLDOWN) return;
        o.ringAt = now;
        o.ringUntil = performance.now() + RING_MS;
        say(o.room + ": alarm clock rings for " + sleepers.join(", "));
        fetch("/api/chat/send", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ room: o.room, text: "⏰ wake up, " + sleepers.join(", ") + "!" }),
        }).catch(function () {});
        dirty = true;
      });
    }

    var last = 0;
    function frame(now) {
      var dt = last ? Math.min((now - last) / 1000, 0.1) : 0;
      last = now;
      if (stepAgents(dt) | stepJanitor(dt, now) | stepSleep(now) || dirty) { draw(); dirty = false; }
      raf = window.requestAnimationFrame(frame);
    }
    var raf = window.requestAnimationFrame(frame);
    var timer = window.setInterval(function () { poll().then(function () { dirty = true; }); }, 3000);
    var alarmTimer = window.setInterval(checkAlarm, 5000);
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
      window.clearInterval(alarmTimer);
    });

    window.addEventListener("resize", function () { dirty = true; });

    load();
  }
});
