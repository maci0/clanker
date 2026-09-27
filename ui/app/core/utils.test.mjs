import assert from "node:assert/strict";
import test from "node:test";
import { clip, graphemes, callableProviders, providerUnusableReason, readJson, classifyLoadFailure, fmtUsd, fmtPct, fmtCompact, fmtCost, recencyGroup } from "./utils.js";


// The availability contract of GET /api/providers: rows the server marked
// `usable:false` stay in the payload (the Models view is inventory) but the
// chat picker and the fallback select build only from the callable set. The
// server side of the same contract is pinned in cli.zig's
// annotateProviderUsability tests; this half pins what the page does with it.

const payload = [
  { name: "anthropic", usable: false, reason: "ANTHROPIC_API_KEY not set" },
  { name: "deepseek", usable: true },
  { name: "legacy-no-field" },
];

test("the picker set omits providers the server cannot call", function () {
  const callable = callableProviders(payload).map(function (p) { return p.name; });
  assert.deepEqual(callable, ["deepseek", "legacy-no-field"]);
});

test("a row without the usable field counts as callable (older server)", function () {
  assert.equal(callableProviders([{ name: "old" }]).length, 1);
});

test("empty and missing lists stay empty rather than throwing", function () {
  assert.deepEqual(callableProviders(null), []);
  assert.deepEqual(callableProviders([]), []);
});

test("the inventory reason is the server's, with a fallback label", function () {
  assert.equal(providerUnusableReason(payload[0]), "ANTHROPIC_API_KEY not set");
  assert.equal(providerUnusableReason({ name: "x", usable: false }), "not configured");
  assert.equal(providerUnusableReason(payload[1]), "");
  assert.equal(providerUnusableReason(payload[2]), "");
});

// A list load fails in two shapes the page must not confuse: a module the
// operator switched off (the route answers 404 with its own reason, a settled
// state) and a request that never got an answer (retryable). loadSessions used
// to fold both into an empty list, so a dead server read as "no conversations
// yet" — docs/reports/bugs/2026-08-22-webui-loadsessions-swallows-failure.md.

test("readJson carries the status onto the error it throws", async function () {
  const res = {
    ok: false,
    status: 404,
    json: function () { return Promise.resolve({ ok: false, error: "sessions module disabled" }); },
  };
  await assert.rejects(readJson(res), function (err) {
    assert.equal(err.message, "sessions module disabled");
    assert.equal(err.status, 404);
    return true;
  });
});

test("readJson carries the status even when the body is not JSON", async function () {
  const res = {
    ok: false,
    status: 502,
    json: function () { return Promise.reject(new Error("not json")); },
  };
  await assert.rejects(readJson(res), function (err) {
    assert.equal(err.status, 502);
    return true;
  });
});

test("a switched-off module is a settled state, not a retryable failure", function () {
  const err = new Error("sessions module disabled");
  err.status = 404;
  const out = classifyLoadFailure(err);
  assert.equal(out.kind, "disabled");
  assert.equal(out.retry, false);
  assert.equal(out.message, "sessions module disabled");
});

test("a 404 that is not a disabled module stays retryable", function () {
  const err = new Error("no such session");
  err.status = 404;
  const out = classifyLoadFailure(err);
  assert.equal(out.kind, "failed");
  assert.equal(out.retry, true);
  assert.equal(out.message, "no such session");
});

test("a server error is retryable and keeps the server's own words", function () {
  const err = new Error("HTTP 500");
  err.status = 500;
  const out = classifyLoadFailure(err);
  assert.equal(out.kind, "failed");
  assert.equal(out.retry, true);
  assert.equal(out.message, "HTTP 500");
});

test("a fetch that never reached the server describes itself", function () {
  const out = classifyLoadFailure(new TypeError("Failed to fetch"));
  assert.equal(out.kind, "failed");
  assert.equal(out.retry, true);
  assert.equal(out.message, "Could not reach the server.");
});

test("a failure with no message at all still says something", function () {
  const out = classifyLoadFailure(null);
  assert.equal(out.kind, "failed");
  assert.equal(out.message, "Could not reach the server.");
});

// The number/percent/currency formatters. A hardcoded "$" + toFixed or a
// hardcoded "K" suffix is the locale bug this pins: the value is right and the
// rendering is not, and only the rendering differs between a US and a German
// reader. Assertions run under the default locale, so they pin that the value
// survives, not which locale a CI machine happens to be set to.

test("a currency amount keeps its digits and its own locale's rendering", function () {
  const four = fmtUsd(0.0001, 4);
  assert.match(four, /0[,.]0001/);
  assert.match(four, /0[,.]0001\s*\$|\$\s*0[,.]0001/);
  assert.match(fmtUsd(3), /\$3/);
  assert.equal(fmtUsd("nonsense"), fmtUsd(0));
});

test("a percentage formats from the 0-100 shape call sites hold", function () {
  assert.match(fmtPct(80, 0), /^80\s*%$/);
  assert.match(fmtPct(12.34), /^12[,.]3\s*%$/);
  assert.match(fmtPct(0, 0), /^0\s*%$/);
});

test("a compact token count abbreviates in the reader's own units", function () {
  assert.equal(fmtCompact(40), "40");
  // Above a thousand the abbreviation is the locale's (K, Mio., 万, …), so
  // the assertion is on the magnitude surviving, not on the suffix.
  const k = fmtCompact(972000);
  assert.match(k, /972|0[,.]97/);
  const m = fmtCompact(225000000);
  assert.match(m, /225|2[,.]25/);
  assert.equal(fmtCompact(999), "999");
});

test("a sub-dollar cost keeps four digits, a larger one two", function () {
  assert.match(fmtCost(0.0001), /0[,.]0001/);
  assert.match(fmtCost(200), /200[,.]00/);
});

// Truncation is a grapheme-cluster operation, not a code-point one. A cut
// between the halves of a surrogate pair yields a lone half, which renders as
// U+FFFD in the page and is not valid input for a server that stores it.
test("clip never cuts a surrogate pair in half", function () {
  const out = clip("😀".repeat(10), 5);
  assert.equal(out, "😀😀😀😀😀…");
  assert.ok(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(out));
});

test("clip never separates a combining mark from its base", function () {
  // "é" written with a combining acute is two code points and one cluster.
  const out = clip("é".repeat(10), 5);
  assert.equal(out, "ééééé…");
});

test("clip keeps a ZWJ emoji sequence whole", function () {
  const family = "\u{1F468}‍\u{1F469}‍\u{1F467}";
  const out = clip(family.repeat(4), 3);
  assert.equal(out, family.repeat(3) + "…");
});

test("graphemes falls back to whole code points without Intl.Segmenter", function () {
  // The fallback path is exercised directly so a platform without Segmenter
  // still gets surrogate pairs intact (it is combining marks it cannot join).
  assert.deepEqual(Array.from(graphemes("a😀b")), ["a", "😀", "b"]);
});

/* The chat rail's day headings. Expectations are built from the local
   calendar, the way Intl renders them, so they read the same on a machine
   whose zone is not the CI one. `atS` is the epoch-seconds shape a session
   record carries; `at` is the same instant in the milliseconds the
   `now` argument takes. */
const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
const atS = (y, m, d, h, min) => Math.floor(new Date(y, m - 1, d, h, min, 0).getTime() / 1000);
const at = (y, m, d, h, min) => new Date(y, m - 1, d, h, min, 0).getTime();

test("a spring-forward weekend is grouped by calendar day, not by 24 hours", function () {
  // 2026-03-29 02:00 -> 03:00 local, so Sunday is 23 hours long and a
  // Saturday session read on the Monday after it is 47.5 hours old: an
  // elapsed-24-hour window files it under "Yesterday" when the calendar says
  // two days back. The zone is set and restored inside this one test, so no
  // other suite in the sweep sees it.
  const before = process.env.TZ;
  process.env.TZ = "Europe/Warsaw";
  try {
    const now = at(2026, 3, 30, 0, 30);
    assert.ok(Math.abs((now - at(2026, 3, 28, 0, 0)) / 3600000 - 47.5) < 1.5);
    assert.equal(recencyGroup(atS(2026, 3, 30, 0, 0), now), rtf.format(0, "day"));
    assert.equal(recencyGroup(atS(2026, 3, 29, 23, 30), now), rtf.format(-1, "day"));
    assert.equal(recencyGroup(atS(2026, 3, 28, 0, 0), now), "Previous 7 days");
  } finally {
    if (before === undefined) delete process.env.TZ;
    else process.env.TZ = before;
  }
});

test("an ordinary week is unchanged, and a future stamp reads as today", function () {
  const now = at(2026, 6, 17, 12, 0);
  assert.equal(recencyGroup(atS(2026, 6, 17, 1, 0), now), rtf.format(0, "day"));
  assert.equal(recencyGroup(atS(2026, 6, 16, 23, 0), now), rtf.format(-1, "day"));
  assert.equal(recencyGroup(atS(2026, 6, 15, 12, 0), now), "Previous 7 days");
  assert.equal(recencyGroup(atS(2026, 6, 11, 12, 0), now), "Previous 7 days");
  assert.equal(recencyGroup(atS(2026, 6, 10, 12, 0), now), "Previous 30 days");
  assert.equal(recencyGroup(atS(2026, 6, 1, 12, 0), now), "Previous 30 days");
  assert.equal(recencyGroup(atS(2026, 4, 1, 12, 0), now), "Older");
  // A clock stepped backwards leaves a session stamped in the future.
  assert.equal(recencyGroup(now + 3600, now), rtf.format(0, "day"));
  assert.equal(recencyGroup(0, now), "Undated");
});
