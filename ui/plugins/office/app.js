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

    /* How long one of the janitor's lines stays up, and how long he says
       nothing afterwards. Both in ms, against performance.now(), because that
       is the clock the frame loop hands him. Two numbers rather than one: with
       only a "next line at" deadline the previous line has nothing to expire
       against, which is exactly how his bubble became permanent. */
    var QUIP_MS = 4500;
    var QUIP_GAP_MS = 9000;
    var alarmOn = van.state(api.storage.get("alarm") === "on" ||
      (api.storage.get("alarm") == null && localStorage.getItem("clanker-office-alarm") === "on"));

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
            api.storage.set("alarm", alarmOn.val ? "on" : "off");
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
    /* The janitor. Always on the floor, walking his rounds: he is the
       comedic relief, not a status lamp (/api/janitor's reclaimable-bytes
       report still arrives as his grumbling, and the log line still names
       the real command). He only actually CLEANS when a clanker makes a
       mess: a board action can drop a pile of garbage at the actor's desk,
       and the janitor rushes over and sweeps it up. Work makes crumbs;
       somebody has to. */
    var janitor = {
      bytes: 0, items: 0,
      x: 1, y: 1, dir: 1, office: 0,
      tx: null, ty: null,          // current waypoint
      pile: null,                  // the pile being rushed / cleaned
      cleaning_until: 0,
      // quipUntil is when the current line comes down; nextQuipAt is when he
      // is allowed to start another. null means he has not spoken yet, so the
      // view opens quietly rather than with a bubble already up.
      quip: null, quipUntil: 0, nextQuipAt: null,
    };
    var PILE_CHANCE = 3;           // 1 in N board actions drops garbage
    /* Short, apologetic, understated: the character says very little, and a
       mascot with a joke for every occasion would be a different one. The
       janitor.zig header records why these are not verbatim quotes. */
    var JANITOR_QUIPS = [
      "Sorry. I walk here.",
      "Is quiet. I like quiet.",
      "I am only cleaner.",
      "Hold my mop.",
      "You train? I walk. Same thing.",
      "Floor is fine. I check anyway.",
      "Is heavy? For you maybe.",
      "I do not lift. I tidy.",
      "First mop. Then we talk.",
      "Is fine. Floor is my gym.",
      "Somebody drop 300 megabyte. I say nothing.",
      "Robots do not eat. So where is crumbs from."
    ];
    var CLEAN_QUIPS = [
      "Who throw this?",
      "Fresh garbage. Is still warm.",
      "I just clean here. Was nine seconds ago.",
      "Is okay. Is job.",
      "You work, I sweep. Is system.",
      "This one signs its garbage. Brave."
    ];

    var quipIdx = 0;
    var instanceName = "";
    var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    /* ---------- toy physics: grab, shake, slap, throw ----------
       A clanker under the pointer is a ragdoll, not an agent: while dragging
       or flying it owns its own x/y and nothing else (walk-to-board, sleep)
       may touch them. Four gestures, cheapest to most drastic:
         pat   tap with almost no travel -> a happy little bounce
         shake held and wiggled fast -> a complaint, repeatable
         slap  a short fast flick -> recoils in place, does not fly
         throw a long fast flick, released -> ragdolls until it hits a wall
       Black & White is the reference: pet and slap were the whole verb set
       before the game escalated, and that is the right amount of verb here
       too -- a training loop this game does not have, played for the joke. */
    var GRAB_RADIUS = TILE * 0.85;
    var PAT_MAX_DIST = 6;          // px; under this a release is a tap
    var PAT_MAX_MS = 350;
    var SLAP_MIN_SPEED = 3;        // tiles/sec
    var THROW_MIN_SPEED = 7;       // tiles/sec; slap band is [SLAP, THROW)
    var THROW_MAX_SPEED = 40;      // clamp so one wild flick can't send them out of frame
    var THROW_SHORT_HOP = 1.5;     // tiles of total travel; fast+short reads as a slap, not a throw
    var SHAKE_REVERSALS = 4;       // direction changes inside the window that count as a shake
    var SHAKE_WINDOW_MS = 420;
    var SHAKE_MIN_PX = 3;          // ignore sub-pixel jitter as a "reversal"
    var SHAKE_COOLDOWN_MS = 900;
    var PAT_BUBBLE_MS = 1400;
    var SLAP_BUBBLE_MS = 1600;
    var SHAKE_BUBBLE_MS = 1600;
    var THROW_BUBBLE_MS = 2200;
    var PAT_BOUNCE_MS = 320;
    var IMPACT_SQUASH_MS = 220;

    /* Positive. A pet, not a status message -- the only gesture here that is
       not a complaint. */
    var PAT_QUIPS = [
      "beep :)",
      "that's the spot",
      "purring.exe",
      "10/10 pat",
      "logging this as positive reinforcement",
      "do that again",
      "affection received, thanks",
      "my uptime just improved",
    ];
    /* A short, close-range flick. Startled and a little offended, not hurt --
       they are still standing where you slapped them. */
    var SLAP_QUIPS = [
      "rude",
      "hey!",
      "was that necessary",
      "I felt that in my weights",
      "noted. filing a complaint.",
      "excuse you",
      "-1 trust score",
      "that's assault, actually",
    ];
    /* Held and wiggled. Dizzy, not hurt -- this one repeats, so it should stay
       light even the fourth time in a row. */
    var SHAKE_QUIPS = [
      "my context window is spinning",
      "PUT ME DOWN",
      "*distressed beeping*",
      "this isn't in my system prompt",
      "I am not a stress ball",
      "nausea.exe has encountered a problem",
      "shaking != debugging",
      "I take it back, I liked the desk",
    ];
    /* Airborne, then a wall. The one gesture with real momentum behind it, so
       these get to be a little more dramatic. */
    var THROW_QUIPS = [
      "*CLANG*",
      "OOF",
      "worth it? no.",
      "achievement unlocked: drywall",
      "I'll allow it. once.",
      "filing an incident report",
      "-10 HP",
      "that wall had it coming",
      "structural integrity: mine, not the wall's",
      "reboot required",
    ];
    /* A prop has no voice; the joke is the room reacting, not it complaining.
       A broken prop becomes a pile at the impact site -- the same mechanic
       the janitor already knows how to find, rush to, and clean, so "the
       janitor comes and comments on it" is free once a prop's throw pushes
       into o.piles instead of drawing itself again. */
    var BREAK_QUIPS = [
      "*CRASH*",
      "well, that's furniture now",
      "RIP",
      "insurance claim pending",
      "that used to be load-bearing",
      "-1 office plant",
      "the shelf did not consent to this",
      "OSHA has entered the chat",
    ];
    function pickQuip(quips, lastRef) {
      if (quips.length === 1) return quips[0];
      var i;
      do { i = Math.floor(Math.random() * quips.length); } while (i === lastRef.i);
      lastRef.i = i;
      return quips[i];
    }
    var patRef = { i: -1 }, slapRef = { i: -1 }, shakeRef = { i: -1 }, throwRef = { i: -1 }, breakRef = { i: -1 };

    function sayQuip(a, text, ms) {
      a.bubble = text;
      var token = {};
      a.bubbleToken = token;
      window.setTimeout(function () {
        if (a.bubbleToken === token) a.bubble = null;
      }, ms);
      dirty = true;
    }

    var lastPlacements = [];      // this frame's office screen positions, for hit-testing
    var drag = null;              // { office, kind: 'agent'|'janitor'|'prop', target, offsetX, offsetY, samples, startedAt, shakeDir, shakeCount, shakeWindowStart, lastShakeAt }

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
    var S_GARBAGE = [6, 1];

    function tile(t, dx, dy) {
      if (!sheetReady) return false;
      ctx2d.drawImage(SHEET, t[0] * TS, t[1] * TS, TS, TS, dx, dy, TILE, TILE);
      return true;
    }

    /* Furniture, live rather than layout-fixed: everything here can be
       picked up, carried, dropped back down, or thrown into a wall and
       broken (desks, the board, and the door stay put -- they are fixtures
       the room's pathfinding and the board mechanic depend on, not toys).
       Built once per office from the deterministic layout, then owned by
       runtime state from there; a reload resets it, which is correct for a
       physics gag with no server side to persist to. */
    var PROP_TILE = { plant: S_PLANT, bin: S_BIN, shelf: S_SHELF, cooler: S_COOLER, picture: S_PICTURE };
    function buildProps(L) {
      var props = [];
      (L.plants || []).forEach(function (p) { props.push({ kind: "plant", x: p.x, y: p.y, w: 1 }); });
      if (L.bin) props.push({ kind: "bin", x: L.bin.x, y: L.bin.y, w: 1 });
      if (L.shelf) props.push({ kind: "shelf", x: L.shelf.x, y: L.shelf.y, w: 1 });
      if (L.cooler) props.push({ kind: "cooler", x: L.cooler.x, y: L.cooler.y, w: 1 });
      if (L.sofa) props.push({ kind: "sofa", x: L.sofa.x, y: L.sofa.y, w: 2 });
      (L.pictures || []).forEach(function (p) { props.push({ kind: "picture", x: p.x, y: p.y, w: 1 }); });
      return props;
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

    /* One prop, at its live (possibly carried or mid-flight) position rather
       than the layout's fixed one. Rotate/squash while airborne or just
       impacted, the same visual grammar drawAgent uses, so a thrown plant
       reads as the same kind of event as a thrown clanker. */
    function drawProp(prop, ox, oy) {
      var px = ox + prop.x * TILE;
      var py = oy + prop.y * TILE;
      var now = performance.now();
      var spinning = !reduced && !!prop.ragdoll;
      var squashed = !reduced && prop.impactUntil && now < prop.impactUntil;
      if (spinning || squashed) {
        ctx2d.save();
        var cx = px + (prop.w * TILE) / 2, cy = py + TILE / 2;
        ctx2d.translate(cx, cy);
        if (spinning) ctx2d.rotate(prop.ragdoll.angle);
        if (squashed) ctx2d.scale(1.25, 0.7);
        ctx2d.translate(-cx, -cy);
      }
      if (prop.kind === "sofa") {
        S_SOFA.forEach(function (s, i) { tile(s, px + i * TILE, py); });
      } else {
        tile(PROP_TILE[prop.kind], px, py);
      }
      if (spinning || squashed) ctx2d.restore();
      if (prop.dragging) {
        ctx2d.strokeStyle = "rgba(0,0,0,0.35)";
        ctx2d.lineWidth = 1;
        ctx2d.beginPath();
        ctx2d.ellipse(px + (prop.w * TILE) / 2, py + TILE - 2, TILE * 0.45, 3, 0, 0, Math.PI * 2);
        ctx2d.stroke();
      }
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

      // Furniture, at wherever it currently is (buildProps keeps insertion
      // order = the old plants/bin/shelf/cooler/sofa/pictures paint order).
      (o.props || []).forEach(function (p) { drawProp(p, ox, oy); });
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
      (o.piles || []).forEach(function (pl) {
        tile(S_GARBAGE, ox + pl.x * TILE, oy + pl.y * TILE);
      });
      if (o.index === janitor.office) drawJanitor(ox, oy, ink);
      // A broken prop has nothing left to draw, but the crash still gets a
      // line: a speech bubble with no speaker, anchored where it happened.
      var now = performance.now();
      var live = [];
      (o.transientBubbles || []).forEach(function (tb) {
        if (now >= tb.until) return;
        live.push(tb);
        bubble(ox + tb.x * TILE, oy + tb.y * TILE, tb.text, ox, L.w);
      });
      o.transientBubbles = live;
    }

    /* The man, then his mop: the handle leans the way he is walking, and it
       has to sit in front of him or it reads as a stick growing out of his
       back. Sized off the sprite, not the tile, so it stays in his hands. */
    function drawJanitor(ox, oy, ink) {
      var px = ox + janitor.x * TILE;
      var py = oy + janitor.y * TILE;
      var now = performance.now();
      var spinning = !reduced && !!janitor.ragdoll;
      var squashed = !reduced && janitor.impactUntil && now < janitor.impactUntil;
      var patted = !reduced && janitor.patUntil && now < janitor.patUntil;
      if (patted) py -= Math.abs(Math.sin((janitor.patUntil - now) / PAT_BOUNCE_MS * Math.PI)) * 5;
      if (spinning || squashed) {
        ctx2d.save();
        var tcx = px + TILE / 2, tcy = py + TILE / 2;
        ctx2d.translate(tcx, tcy);
        if (spinning) ctx2d.rotate(janitor.ragdoll.angle);
        if (squashed) ctx2d.scale(1.25, 0.7);
        ctx2d.translate(-tcx, -tcy);
      }
      janitor.phase = (janitor.phase || 0) + 0.016;
      // He sweeps a horizontal beat, so his facing is his direction of
      // travel -- but held or airborne, he holds his stride rather than
      // marching in the human's hand.
      var moving = !janitor.dragging && !janitor.ragdoll;
      var drawn = character(CH_JANITOR, px, py, moving, janitor.phase,
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
      if (spinning || squashed) ctx2d.restore();
      if (janitor.dragging) {
        ctx2d.strokeStyle = "rgba(0,0,0,0.35)";
        ctx2d.lineWidth = 1;
        ctx2d.beginPath();
        ctx2d.ellipse(px + TILE / 2, py + TILE - 2, TILE * 0.45, 3, 0, 0, Math.PI * 2);
        ctx2d.stroke();
      }
      // A pat/slap/throw reaction outranks his own ambient rounds banter;
      // the window is checked here as well as in the step, so a line cannot
      // outlive it by a frame on a path that draws without stepping.
      if (janitor.bubble) {
        bubble(px, py, janitor.bubble, ox, offices[janitor.office].layout.w);
      } else if (janitor.quip && now < janitor.quipUntil && offices.length > 0) {
        bubble(px, py, janitor.quip, ox, offices[janitor.office].layout.w);
      }
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
      // Each line carries an IEC lamp for its status — green working (and
      // breathing while the clankers are actually on it), amber in review,
      // red blocked — so a glance at the room says how the work stands.
      ctx2d.fillStyle = "#4a4a4a";
      ctx2d.font = "9px ui-monospace, monospace";
      var live = goals.filter(function (g) { return g.status === "active"; }).length;
      ctx2d.fillText("GOALS" + (live ? " · " + live + " live" : ""), wx + 8, wy + 11);
      var now2 = performance.now();
      goals.slice(0, 4).forEach(function (g, i) {
        var ly = wy + 20 + i * 12;
        var lamp = g.status === "active" ? "#2fae4d" : g.status === "review" ? "#c9a50a" : "#c62828";
        // The breath: a working goal's lamp swells, unless motion is reduced.
        var r = 2.5;
        if (g.status === "active" && !reduced) r += 0.8 * Math.abs(Math.sin(now2 / 600 + i));
        ctx2d.fillStyle = lamp;
        ctx2d.beginPath();
        ctx2d.arc(wx + 10, ly + 1, r, 0, Math.PI * 2);
        ctx2d.fill();
        var lineW = Math.min(L.whiteboard.w * TILE - 24, 20 + (hashString(g.objective || "") % 40));
        ctx2d.fillStyle = g.status === "active" ? "#2f6ea8" : "#8a8f96";
        ctx2d.fillRect(wx + 16, ly, lineW, 3);
      });
    }

    function drawAgent(a, ox, oy, ink, o_width) {
      var px = ox + a.x * TILE;
      var py = oy + a.y * TILE;
      var now = performance.now();
      var walking = !!a.walk;
      var spinning = !reduced && !!a.ragdoll;
      var squashed = !reduced && a.impactUntil && now < a.impactUntil;
      var patted = !reduced && a.patUntil && now < a.patUntil;
      // A tiny hop while patted, the same jitter idiom the alarm clock uses.
      if (patted) py -= Math.abs(Math.sin((a.patUntil - now) / PAT_BOUNCE_MS * Math.PI)) * 5;
      if (spinning || squashed) {
        ctx2d.save();
        var cx = px + TILE / 2, cy = py + TILE / 2;
        ctx2d.translate(cx, cy);
        if (spinning) ctx2d.rotate(a.ragdoll.angle);
        if (squashed) ctx2d.scale(1.25, 0.7);
        ctx2d.translate(-cx, -cy);
      }
      if (character(charRow(a.name), px, py, walking, a.phase || 0, a.facing || DIR_DOWN)) {
        // drawn
      } else {
        ctx2d.fillStyle = agentColor(a.name);
        ctx2d.fillRect(px + 4, py + 2, 8, 12);
        ctx2d.fillStyle = ink;
        ctx2d.fillRect(px + 6, py + 4, 2, 2);
        ctx2d.fillRect(px + 10, py + 4, 2, 2);
      }
      if (spinning || squashed) ctx2d.restore();
      if (a.dragging) {
        // A ring under a held clanker, so it is obvious the pointer has it
        // rather than that it teleported.
        ctx2d.strokeStyle = "rgba(0,0,0,0.35)";
        ctx2d.lineWidth = 1;
        ctx2d.beginPath();
        ctx2d.ellipse(px + TILE / 2, py + TILE - 2, TILE * 0.45, 3, 0, 0, Math.PI * 2);
        ctx2d.stroke();
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
      lastPlacements = placements;
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
            // piles and index are set here rather than after the /api/goals
            // round-trip below. The message poll only gates on offices being
            // non-empty, so one landing in between found o.piles undefined and
            // threw inside applyMessage — where poll()'s per-room catch
            // swallowed it, dropping every later message in that batch with
            // the cursor already advanced past them.
            var L = layoutFor(room, agents.length);
            var o = {
              layout: L, cards: cards, agents: agents, props: buildProps(L),
              cursor: cursor, room: room, ringAt: 0, ringUntil: 0, piles: [], index: 0
            };
            seatAgents(o);
            return o;
          });
        }));
      }).then(function (list) {
        offices = list;
        return api.getJSON("/api/goals").catch(function () { return { goals: [] }; });
      }).then(function (g) {
        // Working goals lead; review and blocked follow so the board also
        // says what is waiting on the operator, not only what is running.
        var rank = { active: 0, review: 1, blocked: 2 };
        goals = (g.goals || [])
          .filter(function (x) { return x.status in rank; })
          .sort(function (a, b) { return rank[a.status] - rank[b.status]; });
        // Only the position is settled here; the fields themselves exist from
        // the moment the office does.
        offices.forEach(function (o, i) { o.index = i; });
        return api.getJSON("/api/janitor").catch(function () { return null; });
      }).then(function (jr) {
        if (jr && jr.ok) {
          var had = janitor.items > 0;
          janitor.bytes = jr.bytes;
          janitor.items = jr.items;
          if (jr.items > 0 && !had) {
            say("janitor: " + api.fmt.bytes(jr.bytes) + " to sweep up (clanker janitor --yes)");
          } else if (jr.items === 0 && had) {
            say("janitor: big garbage is gone, back to rounds");
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
      // A clanker mid-toy-interaction owns its own position; the board still
      // gets its state refresh via onArrive, just without the walk.
      if (reduced || agent.dragging || agent.ragdoll) { onArrive(); return; }
      agent.walk = { to: target, home: { x: agent.x, y: agent.y }, phase: "out", onArrive: onArrive };
    }

    /* ---------- janitor navigation ----------
       The floor as a walkability grid: walls, the wall-fixture strip, desks
       with their chairs, the sofa, and the small fixtures are blocked. Small
       (16 x ~14), rebuilt only when a layout is first seen. */
    function blockedGrid(o) {
      // Cached, and invalidated (o._grid = null) wherever a prop's resting
      // position actually changes -- a drop or a break, not every frame of
      // a drag, since the janitor only consults this episodically.
      if (o._grid) return o._grid;
      var L = o.layout;
      var g = [];
      for (var y = 0; y < L.h; y++) g.push(new Array(L.w).fill(false));
      function block(x, yy) { if (yy >= 0 && yy < L.h && x >= 0 && x < L.w) g[yy][x] = true; }
      for (var x0 = 0; x0 < L.w; x0++) { block(x0, 0); block(x0, L.h - 1); }
      for (var y0 = 0; y0 < L.h; y0++) { block(0, y0); block(L.w - 1, y0); }
      for (var ys = 1; ys <= 3; ys++) for (var xs = 1; xs < L.w - 1; xs++) block(xs, ys);
      // Live positions, not the deterministic layout: a prop that has been
      // dragged elsewhere blocks where it is, not where it started.
      (o.props || []).forEach(function (p) {
        var px = Math.round(p.x), py = Math.round(p.y);
        for (var i = 0; i < p.w; i++) block(px + i, py);
      });
      (L.desks || []).forEach(function (d) { block(d.x, d.y); block(d.x + 1, d.y); });
      o._grid = g;
      return g;
    }

    /* Plain A*, 4-neighbour, manhattan heuristic. The grid is tiny, so no
       heap: a linear scan of the open list is faster to read and fast enough. */
    function findPath(o, sx, sy, gx, gy) {
      var g = blockedGrid(o);
      var L = o.layout;
      function free(x, y) { return y >= 0 && y < L.h && x >= 0 && x < L.w && !g[y][x]; }
      // Snap endpoints to the nearest free tile so a pile beside a desk or a
      // janitor mid-stride still resolves.
      function snap(x, y) {
        if (free(x, y)) return { x: x, y: y };
        for (var r = 1; r <= 4; r++) {
          for (var dy = -r; dy <= r; dy++) for (var dx = -r; dx <= r; dx++) {
            if (free(x + dx, y + dy)) return { x: x + dx, y: y + dy };
          }
        }
        return null;
      }
      var start = snap(Math.round(sx), Math.round(sy));
      var goal = snap(Math.round(gx), Math.round(gy));
      if (!start || !goal) return null;
      var open = [{ x: start.x, y: start.y, g: 0, f: 0, prev: null }];
      var seen = {};
      seen[start.x + "," + start.y] = true;
      var guard = L.w * L.h * 4;
      while (open.length > 0 && guard-- > 0) {
        var best = 0;
        for (var i = 1; i < open.length; i++) if (open[i].f < open[best].f) best = i;
        var cur = open.splice(best, 1)[0];
        if (cur.x === goal.x && cur.y === goal.y) {
          var path = [];
          for (var n = cur; n; n = n.prev) path.unshift({ x: n.x, y: n.y });
          return path;
        }
        [[1, 0], [-1, 0], [0, 1], [0, -1]].forEach(function (d) {
          var nx = cur.x + d[0];
          var ny = cur.y + d[1];
          var key = nx + "," + ny;
          if (!free(nx, ny) || seen[key]) return;
          seen[key] = true;
          var gg = cur.g + 1;
          open.push({ x: nx, y: ny, g: gg, f: gg + Math.abs(goal.x - nx) + Math.abs(goal.y - ny), prev: cur });
        });
      }
      return null;
    }

    function pickWaypoint(L) {
      // Anywhere on the open floor, not a corridor: rounds wander the whole
      // lower half of the room, x and y both random, so he reads as a person
      // pottering about rather than a platform sprite on rails.
      var g = blockedGrid(offices[janitor.office]);
      for (var tries = 0; tries < 10; tries++) {
        var wx = 1 + Math.random() * (L.w - 3);
        var wy = Math.min(L.h - 2, 4.5 + Math.random() * (L.h - 6.5));
        if (!g[Math.round(wy)] || !g[Math.round(wy)][Math.round(wx)]) {
          janitor.tx = wx;
          janitor.ty = wy;
          return;
        }
      }
      janitor.tx = L.door.x;
      janitor.ty = L.h - 2;
    }

    /// Says a line, for QUIP_MS, and books the earliest he may say the next
    /// one. Every quip goes through here so none can be set without a deadline
    /// to take it down again.
    function janitorSays(quips, now) {
      janitor.quip = quips[quipIdx % quips.length];
      quipIdx += 1;
      janitor.quipUntil = now + QUIP_MS;
      janitor.nextQuipAt = janitor.quipUntil + QUIP_GAP_MS;
      dirty = true;
    }

    function stepJanitor(dt, now) {
      if (offices.length === 0) return false;
      // A human has him: his rounds, his rush to a pile, all of it waits.
      // His own quip timer still ticks down so an old line does not
      // outlive the interruption and reappear once he is set back down.
      if (janitor.dragging || janitor.ragdoll) {
        if (janitor.quip && now >= janitor.quipUntil) {
          janitor.quip = null;
          dirty = true;
        }
        return true;
      }
      // Take the current line down when its time is up. Before the pile
      // branch, so a line survives neither a rush to fresh garbage nor a
      // scrub: it used to survive both, and everything after it, forever.
      if (janitor.quip && now >= janitor.quipUntil) {
        janitor.quip = null;
        dirty = true;
      }
      // A pile anywhere summons him; oldest first.
      var target_office = null;
      var pile = null;
      for (var i = 0; i < offices.length; i++) {
        var ps = offices[i].piles || [];
        if (ps.length > 0) { target_office = i; pile = ps[0]; break; }
      }
      if (pile && janitor.pile !== pile) {
        janitor.pile = pile;
        janitor.path = null;
        if (janitor.office !== target_office) {
          // He takes the corridor between rooms; drawing that adds nothing,
          // so he appears in the doorway of the room that needs him.
          janitor.office = target_office;
          var L0 = offices[target_office].layout;
          janitor.x = L0.door.x;
          janitor.y = L0.h - 2;
        }
        janitor.quip = null;
      }
      var L = offices[janitor.office].layout;
      if (janitor.pile) {
        if (now < janitor.cleaning_until) return true; // scrubbing in place
        if (janitor.cleaning_until > 0) {
          // Finished: pile gone, one dry line for whoever made it.
          var o = offices[janitor.office];
          var at = o.piles.indexOf(janitor.pile);
          if (at >= 0) o.piles.splice(at, 1);
          janitor.pile = null;
          janitor.cleaning_until = 0;
          janitorSays(CLEAN_QUIPS, now);
          return true;
        }
        if (!janitor.path) {
          janitor.path = findPath(offices[janitor.office], janitor.x, janitor.y, janitor.pile.x, janitor.pile.y);
          janitor.path_i = 0;
        }
        var arrived = false;
        if (reduced || !janitor.path) {
          // Reduced motion (or an unroutable corner case): appear at the mess.
          janitor.x = janitor.pile.x;
          janitor.y = janitor.pile.y;
          arrived = true;
        } else {
          var node = janitor.path[janitor.path_i];
          var dx = node.x - janitor.x;
          var dy = node.y - janitor.y;
          var dist = Math.sqrt(dx * dx + dy * dy);
          var rush = 7 * dt; // garbage is urgent; rounds are not
          if (dist <= rush) {
            janitor.x = node.x;
            janitor.y = node.y;
            janitor.path_i += 1;
            if (janitor.path_i >= janitor.path.length) arrived = true;
          } else {
            janitor.x += (dx / dist) * rush;
            janitor.y += (dy / dist) * rush;
            janitor.dir = dx >= 0 ? 1 : -1;
          }
        }
        if (arrived) {
          janitor.path = null;
          janitor.cleaning_until = now + (reduced ? 1 : 1400);
        }
        return true;
      }
      // Rounds: amble between waypoints, one dry line every so often. The
      // first line waits out a gap, so opening the Office is quiet.
      if (janitor.nextQuipAt === null) janitor.nextQuipAt = now + QUIP_GAP_MS;
      else if (!janitor.quip && now >= janitor.nextQuipAt) janitorSays(JANITOR_QUIPS, now);
      if (reduced) return false;
      if (janitor.tx === null || (Math.abs(janitor.tx - janitor.x) < 0.3 && Math.abs(janitor.ty - janitor.y) < 0.3)) pickWaypoint(L);
      var wx = janitor.tx - janitor.x;
      var wy = janitor.ty - janitor.y;
      var wd = Math.sqrt(wx * wx + wy * wy) || 1;
      var pace = 1.6 * dt;
      janitor.x += (wx / wd) * pace;
      janitor.y += (wy / wd) * pace;
      janitor.dir = wx >= 0 ? 1 : -1;
      return true;
    }

    function stepAgents(dt) {
      var moved = false;
      offices.forEach(function (o) {
        o.agents.forEach(function (a) {
          if (!a.walk || a.dragging || a.ragdoll) return;
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

    /* A launched thing flies at constant velocity (top-down floor, no
       gravity to speak of) until it crosses the room's inner wall line, the
       same boundary blockedGrid treats as solid. First contact ends the
       flight: a bounce-and-repeat would just be more bubbles for no more
       joke, so one impact, one reaction, done. A prop's reaction is to
       break; a clanker's or the janitor's is to complain. */
    var RAGDOLL_MAX_MS = 2000; // safety: a near-zero launch speed still ends the toy eventually
    function stepRagdollThing(thing, o, now, dt) {
      var L = o.layout;
      var w = thing.w || 1;
      var minX = 1, maxX = L.w - 1 - w, minY = 1, maxY = L.h - 2;
      var r = thing.ragdoll;
      thing.x += r.vx * dt;
      thing.y += r.vy * dt;
      r.angle += r.spin * dt;
      var hitWall = thing.x <= minX || thing.x >= maxX || thing.y <= minY || thing.y >= maxY;
      if (!hitWall && now - r.startedAt <= RAGDOLL_MAX_MS) return;
      thing.x = Math.min(Math.max(thing.x, minX), maxX);
      thing.y = Math.min(Math.max(thing.y, minY), maxY);
      thing.ragdoll = null;
      dirty = true;
      if (thing.kind && hitWall) {
        // A prop: breaks into the same pile mechanic the janitor already
        // rushes to and cleans, so "he comes and comments on it" is free.
        var idx = o.props.indexOf(thing);
        if (idx >= 0) o.props.splice(idx, 1);
        o._grid = null; // the tile it occupied is walkable again
        if ((o.piles || []).length < 5) o.piles.push({ x: Math.round(thing.x), y: Math.round(thing.y) });
        say(o.room + ": the " + thing.kind + " did not survive contact with the wall");
        (o.transientBubbles = o.transientBubbles || []).push({
          x: thing.x, y: thing.y, until: now + THROW_BUBBLE_MS, text: pickQuip(BREAK_QUIPS, breakRef),
        });
        // Same idiom as sayQuip's token timeout: one extra frame right at
        // expiry to drop it, rather than polling every frame until then.
        window.setTimeout(function () { dirty = true; }, THROW_BUBBLE_MS);
        return;
      }
      thing.impactUntil = now + IMPACT_SQUASH_MS;
      if (hitWall) sayQuip(thing, pickQuip(THROW_QUIPS, throwRef), THROW_BUBBLE_MS);
    }
    function stepRagdolls(dt, now) {
      var any = false;
      offices.forEach(function (o) {
        o.agents.forEach(function (a) { if (a.ragdoll) { any = true; stepRagdollThing(a, o, now, dt); } });
        // Slice a snapshot: stepRagdollThing may splice a broken prop out of
        // o.props mid-loop, which a live forEach would skip a neighbour for.
        (o.props || []).slice().forEach(function (p) { if (p.ragdoll) { any = true; stepRagdollThing(p, o, now, dt); } });
      });
      if (janitor.ragdoll && offices[janitor.office]) { any = true; stepRagdollThing(janitor, offices[janitor.office], now, dt); }
      return any;
    }

    /* Screen (client) coordinates to a point inside the canvas's own pixel
       space. draw() keeps canvas.style.width/height equal to the backing
       store size (no fractional CSS scaling), so this is a plain offset. */
    function canvasPoint(e) {
      var rect = canvas.getBoundingClientRect();
      return { x: e.clientX - rect.left, y: e.clientY - rect.top };
    }

    /* Nearest grabbable thing under a canvas point, in any office, within
       grab range: a clanker, the janitor (wherever his rounds have taken
       him), or a piece of furniture. Piggybacks on lastPlacements rather
       than re-deriving office layout: the screen position drawOffice used
       this frame is the only one that can be right, since offices reflow
       with the container width. */
    function hitGrabbable(pt) {
      var best = null, bestDist = GRAB_RADIUS;
      function consider(place, kind, thing, w) {
        var cx = place.x + (thing.x + (w || 1) / 2) * TILE;
        var cy = place.y + (thing.y + 0.5) * TILE;
        var d = Math.hypot(pt.x - cx, pt.y - cy);
        if (d < bestDist) { bestDist = d; best = { office: place, kind: kind, target: thing }; }
      }
      lastPlacements.forEach(function (p) {
        p.o.agents.forEach(function (a) { consider(p, "agent", a); });
        (p.o.props || []).forEach(function (prop) { consider(p, "prop", prop, prop.w); });
        if (p.o.index === janitor.office) consider(p, "janitor", janitor);
      });
      return best;
    }

    function officePlacement(o) {
      for (var i = 0; i < lastPlacements.length; i++) if (lastPlacements[i].o === o) return lastPlacements[i];
      return null;
    }

    /* Black & White's hand is the reference: the cursor itself is always
       "ready," not just when it happens to be over something. An open palm,
       sideways -- the pose mid-swing, not mid-point -- so hovering empty
       floor still promises a clanker gets it if the mouse comes back this
       way. Specific to grab/grabbing (browser-standard, already legible)
       only when there is something under it to actually grab. */
    var SLAP_CURSOR = (function () {
      var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="28" height="28" viewBox="0 0 28 28">' +
        '<g transform="rotate(-90 14 14)" fill="#f4d9b0" stroke="#2a1c10" stroke-width="1.5" stroke-linejoin="round">' +
        '<rect x="9" y="12" width="10" height="10" rx="2"/>' +
        '<rect x="6" y="4" width="3" height="10" rx="1.4"/>' +
        '<rect x="10" y="2" width="3" height="12" rx="1.4"/>' +
        '<rect x="14" y="2" width="3" height="12" rx="1.4"/>' +
        '<rect x="18" y="4" width="3" height="10" rx="1.4"/>' +
        "</g></svg>";
      return "url('data:image/svg+xml," + encodeURIComponent(svg) + "') 14 14, pointer";
    })();
    canvas.style.cursor = SLAP_CURSOR; // correct before the first pointermove even fires
    canvas.style.touchAction = "none"; // a drag here is not a page scroll

    canvas.addEventListener("pointerdown", function (e) {
      if (e.button !== undefined && e.button !== 0) return;
      var pt = canvasPoint(e);
      var hit = hitGrabbable(pt);
      if (!hit) return;
      e.preventDefault();
      if (canvas.setPointerCapture) { try { canvas.setPointerCapture(e.pointerId); } catch (err) {} }
      var target = hit.target;
      if (hit.kind === "agent") target.walk = null;
      target.ragdoll = null;
      target.dragging = true;
      var place = hit.office;
      drag = {
        office: place.o, kind: hit.kind, target: target,
        offsetX: pt.x - (place.x + target.x * TILE),
        offsetY: pt.y - (place.y + target.y * TILE),
        samples: [{ x: pt.x, y: pt.y, t: performance.now() }],
        startedAt: performance.now(),
        shakeDir: null, shakeCount: 0, shakeWindowStart: performance.now(),
        lastShakeAt: 0,
      };
      canvas.style.cursor = "grabbing";
      dirty = true;
    });

    canvas.addEventListener("pointermove", function (e) {
      var pt = canvasPoint(e);
      if (!drag) {
        canvas.style.cursor = hitGrabbable(pt) ? "grab" : SLAP_CURSOR;
        return;
      }
      e.preventDefault();
      var place = officePlacement(drag.office);
      if (!place) return; // office reflowed off-frame mid-drag; drop the update, keep the drag
      var L = drag.office.layout;
      var target = drag.target;
      var w = target.w || 1;
      var prev = drag.samples[drag.samples.length - 1];
      target.x = Math.min(Math.max((pt.x - drag.offsetX - place.x) / TILE, 1), L.w - 1 - w);
      target.y = Math.min(Math.max((pt.y - drag.offsetY - place.y) / TILE, 1), L.h - 2);
      if (drag.kind !== "prop") target.facing = facingOf(pt.x - prev.x, pt.y - prev.y, target.facing);
      else target.dir = pt.x >= prev.x ? 1 : -1;

      // Shake detection: only a held clanker or the janitor can be shaken,
      // not furniture. Direction reversals inside a short rolling window.
      if (drag.kind !== "prop") {
        var now = performance.now();
        var dx = pt.x - prev.x;
        if (Math.abs(dx) >= SHAKE_MIN_PX) {
          var dir = dx > 0 ? 1 : -1;
          if (now - drag.shakeWindowStart > SHAKE_WINDOW_MS) {
            drag.shakeCount = 0;
            drag.shakeWindowStart = now;
          }
          if (drag.shakeDir !== null && dir !== drag.shakeDir) drag.shakeCount += 1;
          drag.shakeDir = dir;
          if (drag.shakeCount >= SHAKE_REVERSALS && now - drag.lastShakeAt > SHAKE_COOLDOWN_MS) {
            sayQuip(target, pickQuip(SHAKE_QUIPS, shakeRef), SHAKE_BUBBLE_MS);
            drag.lastShakeAt = now;
            drag.shakeCount = 0;
          }
        }
      }

      drag.samples.push({ x: pt.x, y: pt.y, t: performance.now() });
      if (drag.samples.length > 6) drag.samples.shift();
      dirty = true;
    });

    function endDrag(e) {
      if (!drag) return;
      var target = drag.target;
      var isProp = drag.kind === "prop";
      target.dragging = false;
      canvas.style.cursor = SLAP_CURSOR; // released, but still hovering -- still ready

      var samples = drag.samples;
      var oldest = samples[0], newest = samples[samples.length - 1];
      var dtS = (newest.t - oldest.t) / 1000;
      var travel = Math.hypot(newest.x - oldest.x, newest.y - oldest.y);
      var vx = 0, vy = 0, speed = 0;
      if (dtS > 0.01) {
        vx = (newest.x - oldest.x) / TILE / dtS;
        vy = (newest.y - oldest.y) / TILE / dtS;
        speed = Math.hypot(vx, vy);
      }
      var totalMs = performance.now() - drag.startedAt;

      if (!isProp && travel < PAT_MAX_DIST && totalMs < PAT_MAX_MS) {
        // A tap, not a flick: reward, no physics. Furniture doesn't get
        // patted -- "pick up, place back down, or throw" is its whole verb set.
        target.patUntil = performance.now() + PAT_BOUNCE_MS;
        sayQuip(target, pickQuip(PAT_QUIPS, patRef), PAT_BUBBLE_MS);
      } else if (speed >= THROW_MIN_SPEED && travel / TILE >= THROW_SHORT_HOP) {
        // A real flick with real carry: airborne until the wall says stop
        // (and, for furniture, break).
        if (speed > THROW_MAX_SPEED) {
          var scale = THROW_MAX_SPEED / speed;
          vx *= scale; vy *= scale;
        }
        target.ragdoll = { vx: vx, vy: vy, angle: 0, spin: (Math.random() < 0.5 ? -1 : 1) * Math.min(3 + speed / 3, 14), startedAt: performance.now() };
      } else if (!isProp && speed >= SLAP_MIN_SPEED) {
        // Fast but short: a slap in place, not a launch.
        sayQuip(target, pickQuip(SLAP_QUIPS, slapRef), SLAP_BUBBLE_MS);
        target.impactUntil = performance.now() + IMPACT_SQUASH_MS;
      } else if (isProp) {
        // Plain put-down: the janitor's pathfinding needs to know it moved.
        drag.office._grid = null;
      }
      // Anything slower than SLAP_MIN_SPEED on a clanker/janitor is a plain,
      // silent put-down.

      drag = null;
      dirty = true;
      if (e && e.preventDefault) e.preventDefault();
    }
    canvas.addEventListener("pointerup", endDrag);
    canvas.addEventListener("pointercancel", endDrag);
    // A drag that leaves the canvas keeps going (pointer capture holds it),
    // but a release outside any element still needs to end it.
    window.addEventListener("pointerup", function (e) { if (drag) endDrag(e); });

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
        // Work makes crumbs: some actions leave a pile of garbage by the
        // actor's desk, and the janitor will rush over. Which actions do is
        // decided by the message's own id, so every viewer sees the same mess.
        if (hashString(m.id || m.text) % PILE_CHANCE === 0 && (o.piles || []).length < 3) {
          var px_ = Math.min(Math.max(actor.x + 1, 1), o.layout.w - 2);
          var py_ = Math.min(Math.max(actor.y + 1, 5), o.layout.h - 2);
          o.piles.push({ x: px_, y: py_ });
          say(o.room + ": " + m.from + " threw a pile of garbage on the floor");
          dirty = true;
        }
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

    /* The host never unmounts a view, it only toggles the panel's hidden
       attribute. So all background work gates on visibility: the RAF loop
       parks itself, and the interval callbacks no-op until refresh (called
       on every re-activation) wakes everything back up. */
    function viewHidden() {
      var view = container.closest(".view");
      return !!(view && view.hidden);
    }

    var polling = false;
    function poll() {
      if (polling || offices.length === 0 || viewHidden()) return Promise.resolve();
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
      if (!alarmOn.val || viewHidden()) return;
      var now = nowSec();
      offices.forEach(function (o) {
        var sleepers = o.agents.filter(function (a) { return a.name !== instanceName && asleep(a); })
          .map(function (a) { return a.name; });
        if (sleepers.length === 0) return;
        if (now - (o.ringAt || 0) < RING_COOLDOWN) return;
        o.ringAt = now;
        o.ringUntil = performance.now() + RING_MS;
        say(o.room + ": alarm clock rings for " + sleepers.join(", "));
        api.postJSON("/api/chat/send", {
          room: o.room,
          text: "⏰ wake up, " + sleepers.join(", ") + "!"
        }).catch(function () {});
        dirty = true;
      });
    }

    var last = 0;
    function frame(now) {
      if (viewHidden()) { raf = 0; last = 0; return; }
      var dt = last ? Math.min((now - last) / 1000, 0.1) : 0;
      last = now;
      if (stepAgents(dt) | stepJanitor(dt, now) | stepSleep(now) | stepRagdolls(dt, now) || dirty) { draw(); dirty = false; }
      raf = window.requestAnimationFrame(frame);
    }
    var raf = window.requestAnimationFrame(frame);
    api.onLive(function (ev) {
      if (!ev || ev.t !== "chat" || viewHidden()) return;
      poll().then(function () { dirty = true; });
    });
    // Idle while hidden, like the RAF loop and the janitor poll below:
    // resume() re-polls on re-entry, so nothing is missed by skipping here.
    window.setInterval(function () {
      if (viewHidden()) return;
      poll().then(function () { dirty = true; });
    }, 3000);
    window.setInterval(checkAlarm, 5000);
    window.setInterval(function () {
      if (viewHidden()) return;
      api.getJSON("/api/janitor").then(function (jr) {
        if (!jr || !jr.ok) return;
        janitor.bytes = jr.bytes;
        janitor.items = jr.items;
        dirty = true;
      }).catch(function () {});
    }, 30000);

    // Restart the RAF loop frame() parked while the view was hidden, and
    // catch up on messages missed meanwhile. Idempotent: frame keeps raf
    // truthy while running, and poll() no-ops when one is in flight.
    function resume() {
      dirty = true;
      if (!raf) raf = window.requestAnimationFrame(frame);
      poll().then(function () { dirty = true; });
    }

    /* The refresh hook is the plugin API's resume path, but the host marks a
       view loaded after the first successful mount and never calls the loader
       again, so watch the panel's hidden attribute too: it flips on every
       view switch. */
    this.refresh = resume;
    var panel = container.closest(".view");
    if (panel) {
      new MutationObserver(function () { if (!panel.hidden) resume(); })
        .observe(panel, { attributes: true, attributeFilter: ["hidden"] });
    }

    window.addEventListener("resize", function () { dirty = true; });

    load();
  }
});
