import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { boardActionLine, boardTimeline } from "./board.js";

const here = dirname(fileURLToPath(import.meta.url));
const plugin = readFileSync(join(here, "..", "..", "plugins", "activity", "app.js"), "utf8");

/* One card and the room messages that produced it, in the shape the two
   endpoints actually return: `/api/board` gives `board.cards[]` with a `log`
   array, `/api/chat/messages?room=board` gives `messages[]` of `@todo` lines. */
const CARDS = [
  { id: "c1", title: "Fix the picker", log: [{ ts: 300, who: "clankerydoo", what: "goal run finished" }] },
  { id: "c2", title: "Ads", log: [] },
];
const MESSAGES = [
  { from: "clankerydoo", ts: 500, text: '@todo {"action":"move","todo":"c2","column":"archive"}' },
  { from: "clankerydoo", ts: 400, text: '@todo {"action":"update","todo":"c1","goal":""}' },
  { from: "clankerydoo", ts: 300, text: '@todo {"action":"log","todo":"c1","what":"goal run finished"}' },
  { from: "someone", ts: 200, text: "just talking in the room, not a card action" },
];

test("the timeline carries structural actions, not only log lines", function () {
  const rows = boardTimeline(CARDS, MESSAGES);
  const whats = rows.map(function (r) { return r.what; });
  // The regression: only the `log` action ever reached a card's log array, so
  // a board that was actively being worked on showed nothing but this line.
  assert.ok(whats.includes("moved a card to Archive"));
  // Clearing a card's goal link is an `update`, and reads as one.
  assert.ok(whats.includes("changed no goal link"));
  assert.ok(whats.includes("goal run finished"));
});

test("newest first", function () {
  const rows = boardTimeline(CARDS, MESSAGES);
  const ts = rows.map(function (r) { return r.ts; });
  assert.deepEqual(ts, ts.slice().sort(function (a, b) { return b - a; }));
  assert.equal(rows[0].ts, 500);
});

test("a log action is not shown twice", function () {
  // It arrives on both feeds: as the card's log entry and as the room message
  // that created it. The card's copy wins — it survives the room's history
  // window, and it reads as the note itself rather than "noted: ...".
  const rows = boardTimeline(CARDS, MESSAGES);
  const at300 = rows.filter(function (r) { return r.ts === 300; });
  assert.equal(at300.length, 1);
  assert.equal(at300[0].what, "goal run finished");
});

test("rows name the card they belong to", function () {
  const rows = boardTimeline(CARDS, MESSAGES);
  const move = rows.find(function (r) { return r.ts === 500; });
  // The action names a card id; the title comes from the board.
  assert.equal(move.id, "c2");
  assert.equal(move.card, "Ads");
  // An action against a card the board no longer has still lists, with no
  // invented title: deleted cards are exactly what a timeline is for.
  const orphan = boardTimeline([], [{ from: "x", ts: 900, text: '@todo {"action":"delete","todo":"gone"}' }]);
  assert.equal(orphan.length, 1);
  assert.equal(orphan[0].id, "gone");
  assert.equal(orphan[0].card, "");
});

test("room chatter is not board activity", function () {
  const rows = boardTimeline([], [{ from: "someone", ts: 1, text: "hello" }]);
  assert.deepEqual(rows, []);
  // Malformed action JSON is dropped rather than rendered as a raw line.
  assert.deepEqual(boardTimeline([], [{ from: "x", ts: 1, text: "@todo {not json" }]), []);
});

test("missing feeds degrade instead of throwing", function () {
  assert.deepEqual(boardTimeline(null, null), []);
  assert.deepEqual(boardTimeline(undefined, undefined), []);
  assert.equal(boardTimeline(CARDS, null).length, 1);
});

test("boardActionLine still renders every action the board records", function () {
  assert.equal(boardActionLine('@todo {"action":"move","column":"done"}'), "moved a card to Done");
  assert.equal(boardActionLine("not an action"), null);
});

test("the Activity plugin reads both feeds and merges them", function () {
  assert.match(plugin, /\/api\/chat\/messages\?room=board/);
  assert.match(plugin, /api\.boardTimeline/);
  // The empty state told the reader to move a card, which produced nothing.
  assert.doesNotMatch(plugin, /Move a card, or write a line/);
});
