import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { dayBucket, fmtWhen, groupRunsByDay, matchesRunQuery, runRows, runStartedAt } from "./runs-list.js";

const here = dirname(fileURLToPath(import.meta.url));
const app = readFileSync(join(here, "..", "app.js"), "utf8");
// The Runs view moved out of app.js into a lazily-imported feature module;
// the wiring these tests pin moved with it.
const runsView = readFileSync(join(here, "..", "features", "runs.js"), "utf8");
const markup = readFileSync(join(here, "..", "index.html"), "utf8");
const guest = readFileSync(join(here, "..", "..", "webui.zig"), "utf8");

// 2026-08-16T22:42:57Z, the newest run in the store when the list was built.
const NOW = 1786920177000;

// Local-calendar yesterday at midnight: the day-bucket boundaries under test
// are local midnights, so a fixed "30h before NOW" instant lands on either
// side of yesterday depending on the machine's timezone (CI pins TZ=UTC).
// Yesterday 00:00 local is on yesterday's calendar day and ≥24h before NOW in
// every timezone, which is exactly the "yesterday" contract both labels use.
const yesterdayMidnight = new Date(NOW);
yesterdayMidnight.setDate(yesterdayMidnight.getDate() - 1);
yesterdayMidnight.setHours(0, 0, 0, 0);
const YESTERDAY = yesterdayMidnight.getTime();

test("a run id carries the only timestamp a listing has", function () {
  // `/api/runs` sends run_id, task, provider, duration_ms, nodes and token
  // counts — no start time — so the list dates a row off the id itself.
  assert.equal(runStartedAt({ run_id: "run-1786920177" }), 1786920177000);
  // Nested runs count nanoseconds (src/agent/subagent.zig), not seconds.
  assert.equal(runStartedAt({ run_id: "sub-1786563209053324602" }), 1786563209053);
  assert.equal(runStartedAt({ run_id: "whatever" }), 0);
  assert.equal(runStartedAt(null), 0);
});

test("both id shapes order on the same clock", function () {
  // The Zig-side regression in graph_listing.zig, asserted again here: the
  // list must not fall back to comparing ids as text.
  const older = runStartedAt({ run_id: "sub-1786471458413566380" });
  const newer = runStartedAt({ run_id: "run-1786561572" });
  assert.ok(older < newer);
});

test("fmtWhen says how long ago, then falls back to a date", function () {
  assert.equal(fmtWhen(NOW - 5 * 1000, NOW), "just now");
  assert.equal(fmtWhen(NOW - 12 * 60 * 1000, NOW), "12m ago");
  assert.equal(fmtWhen(NOW - 3 * 3600 * 1000, NOW), "3h ago");
  assert.equal(fmtWhen(YESTERDAY, NOW), "yesterday");
  assert.match(fmtWhen(NOW - 6 * 86400 * 1000, NOW), /^[A-Z][a-z]{2} \d{1,2}$/);
  // An id with no timestamp gets no invented one.
  assert.equal(fmtWhen(0, NOW), "");
});

test("dayBucket names today and yesterday before it names a date", function () {
  assert.equal(dayBucket(NOW - 60 * 1000, NOW), "Today");
  assert.equal(dayBucket(YESTERDAY, NOW), "Yesterday");
  assert.match(dayBucket(NOW - 9 * 86400 * 1000, NOW), /\d/);
  assert.equal(dayBucket(0, NOW), "Undated");
});

test("rows carry what the dropdown could not show", function () {
  const rows = runRows(
    [
      { run_id: "run-1786920177", task: "Do exactly one tool call", provider: "deepseek", duration_ms: 3201, nodes: 4, prompt_tokens: 46831, completion_tokens: 102, parent_run_id: "" },
      { run_id: "sub-1786563209053324602", task: "", provider: "", duration_ms: 0, nodes: 0, prompt_tokens: 0, completion_tokens: 0, parent_run_id: "run-1786562212" },
    ],
    { now: NOW },
  );
  assert.equal(rows.length, 2);
  assert.equal(rows[0].id, "run-1786920177");
  assert.equal(rows[0].when, "just now");
  assert.equal(rows[0].provider, "deepseek");
  assert.equal(rows[0].nodes, 4);
  assert.equal(rows[0].tokens, 46933);
  assert.equal(rows[0].nested, false);
  assert.equal(rows[0].task, "Do exactly one tool call");
  // A sub-run says whose it is; an empty task is labelled, never blank.
  assert.equal(rows[1].nested, true);
  assert.equal(rows[1].parentId, "run-1786562212");
  assert.equal(rows[1].task, "(no task)");
});

test("rows keep the listing's newest-first order", function () {
  const rows = runRows(
    [
      { run_id: "run-1786920177" },
      { run_id: "sub-1786563209053324602" },
      { run_id: "run-1786561572" },
    ],
    { now: NOW },
  );
  assert.deepEqual(rows.map(function (r) { return r.id; }), ["run-1786920177", "sub-1786563209053324602", "run-1786561572"]);
});

test("the filter matches the same things the dropdown matched", function () {
  const run = { run_id: "run-1786920177", task: "Do exactly one tool call", provider: "deepseek" };
  assert.ok(matchesRunQuery(run, ""));
  assert.ok(matchesRunQuery(run, "exactly"));
  assert.ok(matchesRunQuery(run, "1786920177"));
  assert.ok(matchesRunQuery(run, "DEEPSEEK"), "provider is searchable in the list");
  assert.ok(!matchesRunQuery(run, "nothing-like-this"));
  // The `failed` keyword is a state filter, not a text match.
  assert.ok(!matchesRunQuery(run, "failed"));
  assert.ok(matchesRunQuery({ run_id: "run-1", failed: true }, "failed"));
  assert.ok(matchesRunQuery({ run_id: "run-1", ok: false }, ":failed"));
});

test("grouping puts each row under the day it ran", function () {
  // dayBucket's boundaries are local-calendar midnights, so a fixed "8h
  // before NOW" run would land on either side of midnight depending on the
  // machine's timezone (CI pins TZ=UTC, where the old constant fell on the
  // same day; a UTC+8 machine saw it as Yesterday). Derive the Yesterday run
  // from the local calendar instead: a millisecond before today's local
  // midnight is the previous day in every timezone.
  const localMidnight = new Date(NOW);
  localMidnight.setHours(0, 0, 0, 0);
  const justBeforeMidnight = localMidnight.getTime() - 1;
  const groups = groupRunsByDay(
    runRows(
      [
        { run_id: "run-1786920177" },
        { run_id: "run-" + Math.floor(justBeforeMidnight / 1000) },
        { run_id: "run-1786561572" },
      ],
      { now: NOW },
    ),
    NOW,
  );
  assert.equal(groups[0].day, "Today");
  assert.equal(groups[0].rows.length, 1);
  assert.equal(groups[1].day, "Yesterday");
  // Days appear once each, in the order the rows arrived.
  const days = groups.map(function (g) { return g.day; });
  assert.equal(new Set(days).size, days.length);
});

test("the Runs view is wired to the list, not just the select", function () {
  // The select can only show its selected option, so the view needs a
  // container the rows go into and a heading that names it.
  assert.match(markup, /id="run-list"/);
  assert.match(markup, /id="run-list-count"/);
  assert.match(app, /runList: document\.getElementById\("run-list"\)/);
  // Filtering has to rewrite both halves of the picker, or the list keeps
  // showing runs the dropdown has already dropped.
  assert.match(runsView, /renderRunList\(matches\)/);
  // Selection is single-sourced through the select, and the highlight is set
  // wherever a run is actually loaded, so a deep link marks the right row.
  assert.match(runsView, /function selectRunFromList/);
  assert.match(runsView, /markSelectedRunRow\(id\)/);
});

test("no second copy of the failure predicate survives in app.js", function () {
  // app.js used to define its own runFailed reading (r.nodes||[]).some,
  // which threw on a listing entry, where `nodes` is a count.
  assert.ok(!/function runFailed/.test(app), "runFailed belongs to runs-list.js alone");
  assert.ok(!/function runFailed/.test(runsView), "runFailed belongs to runs-list.js alone");
  assert.match(runsView, /from "\.\.\/lib\/runs-list\.js"/);
  // ...and app.js must not pull it back onto the eager path: a chat-only visit
  // downloads app.js and never the Runs view, so this import belongs to the
  // feature module alone.
  assert.ok(!/lib\/runs-list\.js/.test(markup), "no <script> tag may make runs-list eager again");
  assert.ok(!/from "\.\/lib\/runs-list\.js"/.test(app), "app.js must reach the Runs view through import()");
});

test("the guest serves the module it now imports", function () {
  // ui/webui.zig embeds each asset by name; an import with no @embedFile
  // reaches the browser as a 404 and takes the whole module graph with it.
  assert.match(guest, /@embedFile\("app\/lib\/runs-list\.js"\)/);
  assert.match(guest, /"lib\/runs-list\.js"/);
  assert.match(guest, /endsWith\(u8, path, "\/lib\/runs-list\.js"\)/);
  assert.match(guest, /@embedFile\("app\/features\/runs\.js"\)/);
  assert.match(guest, /"features\/runs\.js"/);
  assert.match(guest, /endsWith\(u8, path, "\/features\/runs\.js"\)/);
  assert.match(app, /import\("\.\/features\/runs\.js"\)/);
});
