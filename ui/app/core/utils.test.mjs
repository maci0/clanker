import assert from "node:assert/strict";
import test from "node:test";
import { clip, graphemes, callableProviders, providerUnusableReason, readJson, classifyLoadFailure, fmtUsd, fmtPct, fmtCompact, fmtCost, recencyGroup, plural, fmtAgo, fmtUnit, fmtMs, sessionMatchesFilter, searchFold, searchFoldFind, selectHasValue, calendarDaysAgo } from "./utils.js";

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
    json () { return Promise.resolve({ ok: false, error: "sessions module disabled" }); },
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
    json () { return Promise.reject(new Error("not json")); },
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

// A duration over a minute splits into two parts that must add up to the
// whole. Rounding the seconds alone made 119_999 ms read as "1 min 60 s",
// and the REPL's compactDuration truncates the same value, so one step could
// read 1m 60s in the web UI and 1m 59s in the terminal.
test("a duration over a minute never prints a 60-second remainder", function () {
  assert.match(fmtMs(119999), /^1\D*59\D*$/);
  assert.match(fmtMs(60000), /^1\D*0\D*$/);
  assert.match(fmtMs(3599999), /^59\D*59\D*$/);
  assert.equal(fmtMs("nonsense"), "");
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
    if (before === undefined) { delete process.env.TZ; }
    else { process.env.TZ = before; }
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

// The locale-sensitive formatters. These are the ones a reader in another
// language notices first, so each asserts the shape the fix exists for rather
// than a fixed string (the exact wording comes from the runtime locale).

test("plural picks the form Intl.PluralRules names, not `n === 1`", function () {
  const rules = new Intl.PluralRules();
  const forms = { one: "file", other: "files" };
  // Whatever the runtime locale selects for 1 and 2 is what has to come out,
  // including in a locale where "one" covers 2 as well as 1.
  assert.equal(plural(1, forms), "1 " + forms[rules.select(1)]);
  assert.equal(plural(2, forms), "2 " + forms[rules.select(2)]);
  assert.equal(plural(0, forms), "0 " + forms[rules.select(0)]);
});

test("plural falls back to `other` for a category the caller omitted", function () {
  // A language with more categories than the two-form object a call site
  // passes must render the fallback, never the key name.
  const rules = new Intl.PluralRules();
  const count = [0, 1, 2, 3, 4, 5, 11, 21].find((n) => rules.select(n) !== "one" && rules.select(n) !== "other");

  if (count === undefined) { return; }

  assert.equal(plural(count, { one: "x", other: "y" }), count + " y");
});

test("plural groups a large count the way the locale writes numbers", function () {
  assert.equal(plural(1234, { one: "file", other: "files" }), new Intl.NumberFormat().format(1234) + " files");
});

test("fmtAgo names the elapsed time in the reader's language", function () {
  const now = 1_800_000_000;
  assert.equal(fmtAgo(now - 12 * 60, now), rtf.format(-12, "minute"));
  assert.equal(fmtAgo(now - 3 * 3600, now), rtf.format(-3, "hour"));
  assert.equal(fmtAgo(now - 2 * 86400, now), rtf.format(-2, "day"));
});

test("fmtAgo truncates rather than rounds, so a unit never overruns its own name", function () {
  const now = 1_800_000_000;
  // 59:59 is not 60 minutes, and 23:59 is not 24 hours. Rounding printed
  // "60 minutes ago" and "24 hours ago" beside "1 hour ago" / "yesterday".
  assert.equal(fmtAgo(now - 3599, now), rtf.format(-59, "minute"));
  assert.equal(fmtAgo(now - 86399, now), rtf.format(-23, "hour"));
  // A spring-forward day is 23 hours long, so a stamp a local day old is
  // under 86400 seconds of wall time and stays an hour count.
  assert.equal(fmtAgo(now - 82800, now), rtf.format(-23, "hour"));
  // Rounding the other way: 90 minutes is not 2 hours.
  assert.equal(fmtAgo(now - 5400, now), rtf.format(-1, "hour"));
});

test("fmtAgo reads as now inside the first minute and never says \"ago\"", function () {
  const now = 1_800_000_000;
  assert.equal(fmtAgo(now - 30, now), rtf.format(0, "second"));
  assert.equal(fmtAgo(now + 30, now), rtf.format(0, "second"));
  assert.equal(fmtAgo(undefined, now), "");
});

test("fmtUnit carries the locale's unit spelling, not a glued suffix", function () {
  assert.equal(fmtUnit(1500, "millisecond"), new Intl.NumberFormat(undefined, { style: "unit", unit: "millisecond", unitDisplay: "narrow" }).format(1500));
  assert.equal(fmtUnit(0.5, "second", 1), new Intl.NumberFormat(undefined, { style: "unit", unit: "second", unitDisplay: "narrow", maximumFractionDigits: 1 }).format(0.5));
});

// The rail filter box matches through the shared folding helper, so a query
// typed without the accents still finds the session that has them: a Polish
// or German operator types "zazolc" for "Zażółć", and the old toLowerCase()
// comparison found nothing. The label the rail renders is the same text, so
// the folding has to happen on both sides of the comparison.
test("the session filter matches across diacritics and case", function () {
  const item = { id: "sess-1", title: "Zażółć gęślą jaźń", messages: 3, bytes: 2048 };
  assert.equal(sessionMatchesFilter(item, "zazolc"), true);
  assert.equal(sessionMatchesFilter(item, "GESLA"), true);
  assert.equal(sessionMatchesFilter(item, "jazn"), true);
  assert.equal(sessionMatchesFilter(item, ""), true);
  assert.equal(sessionMatchesFilter(item, "ledger"), false);
});

// Folding is what every filter box now matches through, so the letters NFD
// cannot decompose are the ones that decide whether a non-English title is
// reachable at all: "ł" in Polish, "ø" in Danish, "ß" in German, "æ" in
// Icelandic. Without them a reader types the plain keyboard letter and the
// row they can see does not match.
test("searchFold answers the letters Unicode never decomposed", function () {
  assert.equal(searchFold("Zażółć gęślą jaźń"), "zazolc gesla jazn");
  assert.equal(searchFold("Ørsted"), "orsted");
  assert.equal(searchFold("Straße"), "strasse");
  assert.equal(searchFold("Ængström"), "aengstrom");
});

test("searchFoldFind still maps a folded hit back to the original text", function () {
  const hit = searchFoldFind("Ængström", "aeng");
  assert.deepEqual(hit && [hit.start, hit.end], [0, 3]); // the whole "Æ", both folded letters
  assert.equal(searchFoldFind("Ængström", "z"), null);
});

// The model select, the effort select, the fallback select and the log list all
// rebuild their options and then ask the same question: is the operator's
// current value still one of them. A log filename is a filesystem name, so a
// quote or a bracket in it is a real input, and the selector spelling this
// replaced threw on one — which surfaced as "Could not list logs" rather than
// as the option simply being gone.
test("selectHasValue matches on the option value, whatever the name contains", function () {
  const select = { options: [{ value: "clanker.log" }, { value: 'weird "]name' }, { value: "other.log" }] };
  assert.equal(selectHasValue(select, "clanker.log"), true);
  assert.equal(selectHasValue(select, 'weird "]name'), true);
  assert.equal(selectHasValue(select, "missing.log"), false);
  assert.equal(selectHasValue(select, ""), false);
  assert.equal(selectHasValue(select, null), false);
  assert.equal(selectHasValue(null, "clanker.log"), false);
});

// The session rail and the Runs view both bucket by recency, and both got the
// calendar-day correction from here. A DST spring-forward is the case the
// arithmetic exists for: the local day is 23 hours, so a 24-hour block files
// the previous evening under "Today".
test("calendarDaysAgo counts local days, not 24-hour blocks", function () {
  const evening = new Date(2026, 2, 8, 23, 50).getTime();
  const justAfter = new Date(2026, 2, 9, 0, 10).getTime();
  assert.equal(calendarDaysAgo(evening, justAfter), 1);
  assert.equal(calendarDaysAgo(justAfter, evening), -1);
  assert.equal(calendarDaysAgo(evening, evening), 0);
});
