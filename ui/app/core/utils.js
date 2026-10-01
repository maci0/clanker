// Pure helpers — importable as ES module. No DOM, no `el`, no page state —
// anything here must be callable from another module or a node test without a
// page around it.
/* How many views a digit can reach. A digit is one key, so nine is the whole
   of it — there is no "10" keystroke, and the tenth view onward is reached by
   the palette or the tablist arrows instead.

   Shared rather than restated because all three places that knew this number
   knew a different one: the shortcut table still said "1 – 8" from when there
   were eight views, the palette labelled all fourteen with a number, and only
   the key handler was right. Two of the three were advertising a key that does
   nothing. */
export var view_digit_max = 9;

export function fmtBytes(n) {
  var value = n;
  var unit = "byte";

  if (n >= 1024 * 1024) { value = n / (1024 * 1024); unit = "megabyte"; }
  else if (n >= 1024) { value = n / 1024; unit = "kilobyte"; }

  return new Intl.NumberFormat(undefined, {
    style: "unit", unit, unitDisplay: "short",
    maximumFractionDigits: unit === "megabyte" ? 1 : 0
  }).format(value);
}

/* Grapheme clusters, not code points. `Array.from` keeps a surrogate pair
   together but still cuts a combining acute off its base letter, and cuts a
   zero-width-joiner sequence into separate people, and each half then renders
   as a replacement character in whatever the clipped text ends up in.
   `Intl.Segmenter` is the platform's own UAX #29 implementation, so it is the
   answer rather than a second set of ranges to keep in step with the terminal
   width table. */
var grapheme_segmenter = (typeof Intl !== "undefined" && Intl.Segmenter)
  ? new Intl.Segmenter(undefined, { granularity: "grapheme" })
  : null;

export function graphemes(s) {
  var str = String(s);

  if (!grapheme_segmenter) { return Array.from(str); }

  var out = [];

  for (var seg of grapheme_segmenter.segment(str)) { out.push(seg.segment); }

  return out;
}

export function clip(text, max) {
  var chars = graphemes(text);

  if (chars.length <= max) { return String(text); }

  var cut = chars.slice(0, max).join("");
  var space = cut.lastIndexOf(" ");

  return (space > max * 0.6 ? cut.slice(0, space) : cut).replace(/[\s,;:.\-]+$/, "") + "\u2026";
}

/* A cap the *host* enforces in bytes, cut here in bytes. `clip` above is the
   right cut for a label the browser lays out (grapheme clusters, so a combining
   mark or a ZWJ sequence stays whole) and the wrong one for a value heading
   into a guest or a byte-counted validator: `board`'s title cap is 512 *bytes*
   (`cards.max_title_len`, checked with `.len` in Zig), and a 512-unit slice
   satisfies it only for ASCII. A 300-character objective of two-byte letters is
   600 bytes: `slice(0, 512)` leaves all 300 units untouched, the guest refuses
   the create, and the goal mirror stays pinned to "requested" forever — the
   exact failure the slice at the call site was added to prevent.

   Bytes, not UTF-16 units: `TextEncoder` measures what the host counts, and it
   encodes astral text as the 4 bytes the wire carries, so the two agree where
   `String.length` counts a surrogate pair as 2 and the host counts 4. The cut
   walks back off the replacement character `decode` leaves where the byte limit
   split a sequence, so the caller gets a shorter string rather than a visibly
   corrupted one. */
export function capBytes(text, max) {
  var str = String(text);
  var have_codecs = typeof TextEncoder !== "undefined" && typeof TextDecoder !== "undefined";
  var encoder = have_codecs ? new TextEncoder() : null;

  if (!encoder) {
    /* No encoder to measure with, so no way to be right: a code unit is at
       least one byte and at most three (a surrogate pair is 4 over 2), and
       this bound understates every one of those. Better a short string the
       host accepts than a full one it refuses. */
    if (str.length * 3 <= max) { return str; }
    return str.slice(0, Math.floor(max / 3));
  }

  var bytes = encoder.encode(str);

  if (bytes.length <= max) { return str; }

  var end = max;

  /* A byte limit can land between a lead byte and the continuation bytes that
     finish it. Find that lead byte and drop the partial sequence rather than
     decoding it, which would leave a U+FFFD where a shorter string belongs.
     Walking back over continuation bytes reaches it in at most three steps
     (the longest UTF-8 sequence is four bytes), so the loop cannot run long. */
  var lead = end - 1;

  while (lead >= 0 && (bytes[lead] & 0xc0) === 0x80 && end - lead < 4) lead -= 1;

  if (lead >= 0 && end - lead < seqLen(bytes[lead])) end = lead;

  return new TextDecoder().decode(bytes.subarray(0, end));
}

/* How many bytes the UTF-8 sequence starting at this lead byte needs. A byte
   that is not a valid lead has no sequence, and the caller keeps it as the
   one-byte unit `encode` produced for it. */
function seqLen(lead) {
  if (lead < 0xc2 || lead > 0xf4) { return 1; }
  if (lead < 0xe0) { return 2; }
  if (lead < 0xf0) { return 3; }
  return 4;
}

export function fuzzyMatch(query, text) {
  if (!query) { return true; }

  var t = searchFold(text);
  var q = searchFold(query);
  var qi = 0;

  for (var i = 0; i < t.length && qi < q.length; i++) {
    if (t.charAt(i) === q.charAt(qi)) { qi += 1; }
  }

  return qi === q.length;
}

function isCombiningMark(ch) {
  var c = ch.charCodeAt(0);

  return c >= 0x0300 && c <= 0x036f;
}

/* Latin letters NFD cannot decompose: Polish "ł" is not "l" plus a mark. */
var UNDECOMPOSED = {
  "Æ": "ae", "æ": "ae", "Œ": "oe", "œ": "oe", "Ø": "o", "ø": "o",
  "Đ": "d", "đ": "d", "Ð": "d", "ð": "d", "Þ": "th", "þ": "th",
  "Ħ": "h", "ħ": "h", "ı": "i", "Ł": "l", "ł": "l", "ß": "ss"
};

function searchFoldWithMap(str) {
  var s = String(str);
  var folded = "";
  var ranges = [];
  var i = 0;

  while (i < s.length) {
    var cp = s.codePointAt(i);
    var len = cp > 0xffff ? 2 : 1;
    var chunk = s.slice(i, i + len);
    var decomposed = Array.from(chunk.normalize("NFD"));
    var foldedChunk = "";

    for (var j = 0; j < decomposed.length; j++) {
      if (isCombiningMark(decomposed[j])) { continue; }

      // Lowercase, then drop the marks it introduced (Turkish "İ").
      var low = UNDECOMPOSED[decomposed[j]] || decomposed[j].toLocaleLowerCase();

      for (var c = 0; c < low.length; c++) {
        if (!isCombiningMark(low[c])) { foldedChunk += low[c]; }
      }
    }

    for (var k = 0; k < foldedChunk.length; k++) {
      folded += foldedChunk[k];
      ranges.push([i, i + len]);
    }

    i += len;
  }

  return { folded, ranges };
}

/* Accent-insensitive substring search with original-string indices for
   highlighting. `fromFolded` is the folded offset to continue from. */
export function searchFoldFind(text, needle, fromFolded) {
  if (!needle) { return { start: 0, end: 0, next: fromFolded || 0 }; }

  var tm = searchFoldWithMap(text);
  var nm = searchFoldWithMap(needle);

  if (!nm.folded) { return null; }

  var at = tm.folded.indexOf(nm.folded, fromFolded || 0);

  if (at === -1) { return null; }

  return {
    start: tm.ranges[at][0],
    end: tm.ranges[at + nm.folded.length - 1][1],
    next: at + nm.folded.length
  };
}

export function searchFold(value) {
  return searchFoldWithMap(value).folded;
}

export function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, function (c) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
  });
}

export function fmtMs(ms) {
  if (typeof ms !== "number" || !isFinite(ms)) { return ""; }

  if (ms < 1000) { return fmtUnit(ms, "millisecond"); }

  if (ms < 60000) { return fmtUnit(ms / 1000, "second", 1); }

  // Floor both halves. Rounding the seconds made the 59.999s remainder print
  // as "60 s" beside "1 min", and the two surfaces that format the same
  // duration (the REPL's compactDuration) truncate, so a step could read
  // 1m 60s here and 1m 59s there.
  var mins = Math.floor(ms / 60000);
  var seconds = Math.floor((ms % 60000) / 1000);

  return fmtUnit(mins, "minute") + " " + fmtUnit(seconds, "second");
}

/* A past instant as "3 hours ago" in the reader's language. The hand-rolled
   "3h ago" this replaces abbreviated the unit in English and glued a suffix
   on, which no other language builds that way; `numeric:"auto"` also collapses
   yesterday and tomorrow onto their own words. `seconds` is the stamp, not a
   duration, so the result is always in the past. */
var relative_time = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

export function fmtAgo(seconds, nowSeconds) {
  if (typeof seconds !== "number" || !isFinite(seconds)) { return ""; }

  var now = typeof nowSeconds === "number" && isFinite(nowSeconds) ? nowSeconds : Date.now() / 1000;
  var delta = seconds - now;
  var abs = Math.abs(delta);

  if (abs < 60) { return relative_time.format(0, "second"); }

  // Truncate toward zero, the way fmtMs truncates, so a unit never overruns
  // its own name: rounding printed "60 minutes ago" for 59:59 and "24 hours
  // ago" for 23:59, both a bigger age than the stamp carries. Truncating also
  // keeps a spring-forward day (23 wall-clock hours) in the hour bucket
  // instead of promoting it a day early. `Math.floor` is the wrong helper
  // here: delta is negative, and flooring -59.98 is -60.
  if (abs < 3600) { return relative_time.format(Math.trunc(delta / 60), "minute"); }

  if (abs < 86400) { return relative_time.format(Math.trunc(delta / 3600), "hour"); }

  return relative_time.format(Math.trunc(delta / 86400), "day");
}

export function fmtInt(n) {
  return (typeof n === "number" ? n : 0).toLocaleString();
}

/* A count and its noun, with the form chosen by Intl.PluralRules rather than
   by `n === 1`. English has two categories, so the ternary is right here and
   wrong everywhere else: Polish counts one/few/many, Arabic zero/one/two/few/
   many/other, and `n === 1` picks "one" for 21 in both, so 21 files reads
   "21 file". `forms` is keyed by CLDR category; a category the caller left out
   falls back to `other`, so the two-form object every call site passes still
   renders in a language with more forms rather than printing the key name. */
var plural_rules = new Intl.PluralRules();

export function plural(n, forms) {
  var count = typeof n === "number" && isFinite(n) ? n : 0;

  return fmtInt(count) + " " + (forms[plural_rules.select(count)] || forms.other);
}

/* A value in a named unit, with the locale's own unit spelling and spacing.
   The narrow forms are the abbreviations every locale defines ("ms", "1,5 s",
   "1.5 s"), which is what a metric tile wants; a hardcoded suffix next to the
   number reads as `$0,0001` nowhere and `0,0001 $` outside the US. */
export function fmtUnit(v, unit, digits) {
  var value = typeof v === "number" && isFinite(v) ? v : 0;
  var opts = { style: "unit", unit, unitDisplay: "narrow" };

  if (typeof digits === "number") { opts.maximumFractionDigits = digits; }

  return new Intl.NumberFormat(undefined, opts).format(value);
}

/* Currency, percent and compact counts go through Intl: a hardcoded "$" plus
   toFixed reads as `$0,0001` nowhere and `0,0001 $` outside the US. `digits`
   is the fraction-digit count; omitted means "as needed, at most 4". */
export function fmtUsd(n, digits) {
  var v = typeof n === "number" && isFinite(n) ? n : 0;
  var d = typeof digits === "number" ? digits : 0;

  return new Intl.NumberFormat(undefined, {
    style: "currency", currency: "USD", minimumFractionDigits: d,
    maximumFractionDigits: typeof digits === "number" ? d : 4
  }).format(v);
}

/* `value` is a percentage already (80, not 0.8); Intl wants the fraction. */
export function fmtPct(value, digits) {
  var v = typeof value === "number" && isFinite(value) ? value : 0;

  return new Intl.NumberFormat(undefined, {
    style: "percent", maximumFractionDigits: digits == null ? 1 : digits
  }).format(v / 100);
}

/* K/M are English abbreviations; German reads "225,0 Mio.". */
export function fmtCompact(n) {
  var v = typeof n === "number" && isFinite(n) ? n : 0;

  if (Math.abs(v) < 1000) { return fmtInt(Math.round(v)); }

  return new Intl.NumberFormat(undefined, {
    notation: "compact", minimumFractionDigits: 1, maximumFractionDigits: 1
  }).format(v);
}

export function fmtCost(n) {
  var v = typeof n === "number" ? n : 0;

  // Sub-dollar amounts (a single card or turn) need the extra precision;
  // a system-wide total reads better as $200.00 than $200.0000.
  return fmtUsd(v, Math.abs(v) >= 1 ? 2 : 4);
}

export function formatChatTime(ts) {
  if (!ts) { return ""; }

  var d = new Date(ts * 1000);

  return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

export function fmtDeadline(ts) {
  if (!ts) { return ""; }

  var d = new Date(ts * 1000);
  var now = new Date(); now.setHours(0,0,0,0);
  var dd = new Date(d); dd.setHours(0,0,0,0);
  var diffDays = Math.round((dd - now) / 86400000);
  var dateStr = d.toLocaleDateString(undefined, { month: "short", day: "numeric" });

  if (diffDays >= -7 && diffDays <= 7) {
    var rel = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }).format(diffDays, "day");

    return rel + " \u00b7 " + dateStr;
  }

  return dateStr;
}

/* The server explains itself — "sessions module disabled", "no such model for
   that provider", "an image exceeds the 4 MB limit" — and the page used to
   replace all of it with a status code, so a switched-off module read as a
   broken page. Every response goes through here. */
/* The in-flight half of showLoadError. A list that reports "Loading…" on its
   sr-only status line is still a blank panel for as long as the fetch takes,
   which reads as "nothing here". Put the line where the rows will land. */
export function showLoading(container, message) {
  if (!container) { return null; }

  var p = document.createElement("p");
  p.className = "run-empty";
  p.textContent = message || "Loading…";
  container.textContent = "";
  container.appendChild(p);

  return p;
}

export function readJson(r) {
  // The status rides along on the error: the reason string alone cannot tell
  // a switched-off module (404 with its own words) from a server that broke
  // while answering, and callers have to tell those apart.
  var fail = function (msg) {
    var err = new Error(msg);
    err.status = r.status;

    return err;
  };

  return r.json().then(function (d) {
    if (!r.ok) { throw fail((d && d.error) || "HTTP " + r.status); }

    return d;
  }, function () {
    // A body that is not JSON at all still has to fail with something useful.
    if (!r.ok) { throw fail("HTTP " + r.status); }

    return {};
  });
}

/* The JSON POST every config write in the UI is; a missing body is `{}`. */
export function postJson(path, body) {
  return fetch(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body == null ? {} : body) }).then(readJson);
}

/* A list load fails in two shapes a panel must not confuse. A module the
   operator switched off is a settled state — the route answers 404 with its
   own reason and retrying it will answer the same thing forever. Anything
   else is a load that did not complete and is worth another try. Folding both
   into an empty list is what made a dead server read as "no conversations
   yet" (docs/reports/bugs/2026-08-22-webui-loadsessions-swallows-failure.md).
   A fetch rejected before any response has no status and no useful message,
   so it is named here rather than shown as "undefined". */
export function classifyLoadFailure(err) {
  var msg = (err && err.message) || "";

  if (err && err.status === 404 && /\bdisabled\b/i.test(msg)) {
    return { kind: "disabled", retry: false, message: msg };
  }

  // A fetch rejected before any response carries neither a status nor a
  // message worth showing, and `msg` is already empty for a null `err`, so
  // that is the one test to write.
  if (!msg || typeof err.status !== "number") {
    return { kind: "failed", retry: true, message: "Could not reach the server." };
  }

  return { kind: "failed", retry: true, message: msg };
}

export function newSessionId() {
  if (window.crypto && window.crypto.randomUUID) { return window.crypto.randomUUID(); }

  return "sess-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
}

export function summarizeTitle(raw) {
  var t = (raw || "").replace(/\s+/g, " ").trim();

  if (!t) { return "(untitled)"; }

  if (t.indexOf("fork of ") === 0 || t.indexOf("branch of ") === 0) { return clip(t, 28); }

  var skip = { a:1, an:1, the:1, to:1, of:1, for:1, and:1, or:1, in:1, on:1, at:1, is:1, are:1, be:1, been:1, being:1, should:1, would:1, could:1, can:1, will:1, just:1, please:1, this:1, that:1, it:1, with:1, from:1, as:1, by:1, if:1, so:1, do:1, does:1, did:1, not:1, no:1, we:1, i:1, you:1, my:1, our:1, me:1, have:1, has:1, had:1, how:1, what:1, when:1, where:1, why:1, also:1, need:1, want:1, make:1, add:1 };
  var parts = t.split(" ");
  var words = [];
  // Trim punctuation with \p{L}\p{N}, not [A-Za-z0-9]: the ASCII class ate
  // accents off word edges ("Água" became "gu") and stripped a CJK title to
  // nothing; a letter is a letter in any script.
  var trimWord = function (w) { return w.replace(/^[^\p{L}\p{N}']+|[^\p{L}\p{N}']+$/gu, ""); };

  for (var i = 0; i < parts.length && words.length < 3; i++) {
    var w = trimWord(parts[i]);

    if (!w) { continue; }

    if (skip[w.toLowerCase()]) { continue; }

    words.push(w);
  }

  if (!words.length) {
    for (var j = 0; j < parts.length && words.length < 2; j++) {
      var w2 = trimWord(parts[j]);

      if (w2) { words.push(w2); }
    }
  }

  // Codepoints, not UTF-16 units: a 28-unit cut lands inside a surrogate
  // pair on any astral emoji and ships a lone half downstream.
  var joined = words.join(" ") || t;
  var cps = Array.from(joined);
  var out = cps.length > 28 ? cps.slice(0, 28).join("") : joined;

  return out || "(untitled)";
}

export function sessionLabel(s) {
  var title = summarizeTitle(s.title || "");
  title = clip(title, 28);
  var label = title + "  \u00b7  " + plural(s.messages, { one: "msg", other: "msgs" });

  // Transcript weight, because agent.compact_threshold_bytes is measured in
  // exactly these bytes and compaction is otherwise invisible until it fires.
  if (typeof s.bytes === "number" && s.bytes > 0) { label += "  \u00b7  " + fmtBytes(s.bytes); }

  return label;
}

/* The rail filter box says "Filter by title…". Matching only sessionLabel
   misses any word summarizeTitle dropped, so "ledger" would not find
   "Investigate the schedule run-due empty ledger". The compact label stays
   a fallback so a typed "12 msgs" still works. */
export function sessionMatchesFilter(item, q) {
  if (!q) { return true; }

  var needle = searchFold(String(q));

  if (searchFold(item.title || "").indexOf(needle) !== -1) { return true; }

  if (searchFold(item.id || "").indexOf(needle) !== -1) { return true; }

  return searchFold(sessionLabel(item)).indexOf(needle) !== -1;
}

/* Whole calendar days from `since` back to `now`, not 24-hour blocks: a run at
   23:50 was "yesterday" by 00:10, however few hours have passed. The session
   rail and the Runs view both group by recency and each had its own copy. */
export function calendarDaysAgo(sinceMs, nowMs) {
  var a = new Date(sinceMs);
  var b = new Date(nowMs);
  a.setHours(0, 0, 0, 0);
  b.setHours(0, 0, 0, 0);

  return Math.round((b - a) / 86400000);
}

/* Conversations group by when they were last touched, because that is how
   you look for one: "the thing I was doing this morning", not an id.
   `now` is a parameter so the grouping is testable. */
export function recencyGroup(updated, nowMs) {
  if (!updated) { return "Undated"; }

  var now = typeof nowMs === "number" ? nowMs : Date.now();
  // A clock stepped backwards puts a session in the future; it belongs with
  // today, not with yesterday.
  var days = Math.max(0, calendarDaysAgo(updated * 1000, now));

  if (days === 0) { return relative_time.format(0, "day"); }

  if (days === 1) { return relative_time.format(-1, "day"); }

  if (days < 7) { return "Previous 7 days"; }

  if (days < 30) { return "Previous 30 days"; }

  return "Older";
}

/* Answers are model output, and a prompt-injected tool result or RAG
   document can steer the model into emitting a markdown link or image whose
   target is a `javascript:` URL. Mirrors the scheme allowlist already used
   for peer URLs: only a scheme that cannot execute script is ever assigned
   to href/src. */
export function isSafeLinkUrl(url) {
  return /^(https?:|mailto:)/i.test(url);
}

export function splitRow(line) {
  var t = line.trim().replace(/^\|/, "").replace(/\|$/, "");

  return t.split("|");
}

/* JSON-shaped text (a tool result, most often) is unreadable as one line
   and hljs has no way to know it's JSON without a fence's language tag.
   Only untagged text is tried against JSON.parse: reformatting a block the
   author explicitly fenced as something else overrides a stated intent, and
   bare `42` or `"a"` parses as JSON too. */
export function prettyJsonIfPossible(text) {
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch (e) {
    return null;
  }
}

export function hashName(s) {
  var h = 0;

  for (var i = 0; i < s.length; i++) { h = (h * 31 + s.charCodeAt(i)) | 0; }

  return h >>> 0;
}

export function peerColor(name) {
  return "hsl(" + (hashName(name || "") % 360) + " 35% 62%)";
}

export function parseCssColor(color) {
  var s = String(color || "").trim();
  var m = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i.exec(s);

  if (m) { return [+m[1], +m[2], +m[3]]; }

  if (s.charAt(0) === "#") {
    var h = s.slice(1);

    if (h.length === 3) { h = h.replace(/./g, function (c) { return c + c; }); }

    if (h.length === 6 && /^[0-9a-fA-F]{6}$/.test(h)) {
      var n = parseInt(h, 16);

      return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
    }
  }

  return null;
}

export function cssColorAlpha(color, a) {
  var rgb = parseCssColor(color);

  return rgb ? "rgba(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + "," + a + ")" : color;
}

export function cssColorMix(a, b, t) {
  var ca = parseCssColor(a);
  var cb = parseCssColor(b);

  if (!ca || !cb) { return a; }

  var u = Math.max(0, Math.min(1, t));

  return "rgb(" + Math.round(ca[0] + (cb[0] - ca[0]) * u) + "," +
    Math.round(ca[1] + (cb[1] - ca[1]) * u) + "," +
    Math.round(ca[2] + (cb[2] - ca[2]) * u) + ")";
}

export function themeToken(name) {
  if (typeof document === "undefined" || !document.documentElement) { return ""; }

  var v = (getComputedStyle(document.documentElement).getPropertyValue(name) || "").trim();
  var aliased = /^var\(\s*([--A-Za-z0-9_]+)\s*\)$/.exec(v);

  return aliased ? themeToken(aliased[1]) : v;
}


/* GET /api/providers rows carry `usable` (and `reason` when false): the
   server's own verdict on whether *it* can call the provider — its environ,
   its loopback ports — computed with the same gate the TUI /model picker
   applies. The chat model picker and the fallback select consume only the
   callable set; the Models view keeps the full list as inventory and shows
   the reason. A row without the field (an older server) counts as callable,
   so a mixed deploy degrades to the old behavior rather than an empty picker. */
export function callableProviders(list) {
  return (list || []).filter(function (p) { return !!p && p.usable !== false; });
}

export function providerUnusableReason(p) {
  if (!p || p.usable !== false) { return ""; }

  return p.reason || "not configured";
}

/* "Does this <select> still hold this value", behind every place that rebuilds
   a select's options and puts the operator back where they were. Written
   three times over with three selector escapes, and a name carrying a quote
   or a bracket made querySelector throw. Walking `options` escapes nothing. */
export function selectHasValue(select, value) {
  if (!select || value == null || value === "") { return false; }

  var options = select.options || [];

  for (var i = 0; i < options.length; i++) {
    if (options[i].value === String(value)) { return true; }
  }

  return false;
}

/* Every view's header carries a Refresh button, and they were wired a dozen
   different ways: some disabled while the fetch ran, most said nothing at all,
   and three (Goal activity, Tools, Usage) had no listener behind them at all —
   a press that looked like a press and did nothing. One helper so a press
   always reads as one: the button goes disabled for as long as the load takes,
   then comes back. `load` may return a promise or nothing. Idempotent per
   button, because several views re-run their bind on every open. */
export function wireRefresh(button, load) {
  if (!button || button._refreshBound) { return; }

  button._refreshBound = true;
  button.addEventListener("click", function () {
    button.disabled = true;
    var done;

    try { done = load(); } catch (_) { done = null; }

    var free = function () { button.disabled = false; };

    if (done && typeof done.then === "function") { done.then(free, free); }
    else { free(); }
  });
}

/* Unicode properties, not ASCII: these counts come from Intl (shell.test.ts).
   GROUP_SEP is the CLDR digit-group set; \p{M} a decomposed spelling. */
const GROUP_SEP = ",.\\u00a0\\u202f\\u2009\\u2019\\u066c ";
const INVENTORY_STATUS_RE =
  new RegExp("^(?:\\p{Nd}+(?:[" + GROUP_SEP + "]*\\p{Nd}+)*|No)\\s[\\p{L}\\p{M}\\s-]{1,40}?(?:\\syet)?[.\\u3002\\uff0e]$", "u");

/* A view's inventory line ("7 skills.", "No prompts.", "43 items.") restates
   the list the view is already showing, so the status-to-toast mirror skips
   it; errors and the results of an operator's action still toast. */
export const isInventoryStatus = (text) => INVENTORY_STATUS_RE.test(String(text).trim());
