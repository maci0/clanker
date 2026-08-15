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
    style: "unit", unit: unit, unitDisplay: "short",
    maximumFractionDigits: unit === "megabyte" ? 1 : 0
  }).format(value);
}

export function clip(text, max) {
  var chars = Array.from(String(text));
  if (chars.length <= max) return String(text);
  var cut = chars.slice(0, max).join("");
  var space = cut.lastIndexOf(" ");
  return (space > max * 0.6 ? cut.slice(0, space) : cut).replace(/[\s,;:.\-]+$/, "") + "\u2026";
}

export function fuzzyMatch(query, text) {
  if (!query) return true;
  var t = searchFold(text);
  var q = searchFold(query);
  var qi = 0;
  for (var i = 0; i < t.length && qi < q.length; i++) {
    if (t.charAt(i) === q.charAt(qi)) qi += 1;
  }
  return qi === q.length;
}

function isCombiningMark(ch) {
  var c = ch.charCodeAt(0);
  return c >= 0x0300 && c <= 0x036f;
}

export function searchFoldWithMap(str) {
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
      if (isCombiningMark(decomposed[j])) continue;
      foldedChunk += decomposed[j].toLocaleLowerCase();
    }
    for (var k = 0; k < foldedChunk.length; k++) {
      folded += foldedChunk[k];
      ranges.push([i, i + len]);
    }
    i += len;
  }
  return { folded: folded, ranges: ranges };
}

/* Accent-insensitive substring search with original-string indices for
   highlighting. `fromFolded` is the folded offset to continue from. */
export function searchFoldFind(text, needle, fromFolded) {
  if (!needle) return { start: 0, end: 0, next: fromFolded || 0 };
  var tm = searchFoldWithMap(text);
  var nm = searchFoldWithMap(needle);
  if (!nm.folded) return null;
  var at = tm.folded.indexOf(nm.folded, fromFolded || 0);
  if (at === -1) return null;
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
  if (typeof ms !== "number" || !isFinite(ms)) return "";
  if (ms < 1000) return new Intl.NumberFormat(undefined, { style: "unit", unit: "millisecond", unitDisplay: "narrow" }).format(ms);
  if (ms < 60000) return new Intl.NumberFormat(undefined, { style: "unit", unit: "second", unitDisplay: "narrow", maximumFractionDigits: 1 }).format(ms / 1000);
  var mins = Math.floor(ms / 60000);
  var seconds = Math.round((ms % 60000) / 1000);
  var minuteText = new Intl.NumberFormat(undefined, { style: "unit", unit: "minute", unitDisplay: "narrow" }).format(mins);
  var secondText = new Intl.NumberFormat(undefined, { style: "unit", unit: "second", unitDisplay: "narrow" }).format(seconds);
  return minuteText + " " + secondText;
}

export function fmtInt(n) {
  return (typeof n === "number" ? n : 0).toLocaleString();
}

export function fmtCost(n) {
  var v = typeof n === "number" ? n : 0;
  // Sub-dollar amounts (a single card or turn) need the extra precision;
  // a system-wide total reads better as $200.00 than $200.0000.
  var digits = Math.abs(v) >= 1 ? 2 : 4;
  return new Intl.NumberFormat(undefined, {
    style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits
  }).format(v);
}

export function formatChatTime(ts) {
  if (!ts) return "";
  var d = new Date(ts * 1000);
  return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

export function fmtDeadline(ts) {
  if (!ts) return "";
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
export function readJson(r) {
  return r.json().then(function (d) {
    if (!r.ok) throw new Error((d && d.error) || "HTTP " + r.status);
    return d;
  }, function () {
    // A body that is not JSON at all still has to fail with something useful.
    if (!r.ok) throw new Error("HTTP " + r.status);
    return {};
  });
}

export function newSessionId() {
  if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
  return "sess-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);
}

export function summarizeTitle(raw) {
  var t = (raw || "").replace(/\s+/g, " ").trim();
  if (!t) return "(untitled)";
  if (t.indexOf("fork of ") === 0 || t.indexOf("branch of ") === 0) return clip(t, 28);
  var skip = { a:1, an:1, the:1, to:1, of:1, for:1, and:1, or:1, in:1, on:1, at:1, is:1, are:1, be:1, been:1, being:1, should:1, would:1, could:1, can:1, will:1, just:1, please:1, this:1, that:1, it:1, with:1, from:1, as:1, by:1, if:1, so:1, do:1, does:1, did:1, not:1, no:1, we:1, i:1, you:1, my:1, our:1, me:1, have:1, has:1, had:1, how:1, what:1, when:1, where:1, why:1, also:1, need:1, want:1, make:1, add:1 };
  var parts = t.split(" ");
  var words = [];
  for (var i = 0; i < parts.length && words.length < 3; i++) {
    var w = parts[i].replace(/^[^A-Za-z0-9']+|[^A-Za-z0-9'-]+$/g, "");
    if (!w) continue;
    if (skip[w.toLowerCase()]) continue;
    words.push(w);
  }
  if (!words.length) {
    for (var j = 0; j < parts.length && words.length < 2; j++) {
      var w2 = parts[j].replace(/^[^A-Za-z0-9']+|[^A-Za-z0-9'-]+$/g, "");
      if (w2) words.push(w2);
    }
  }
  var out = (words.join(" ") || t).slice(0, 28);
  return out || "(untitled)";
}

export function sessionLabel(s) {
  var title = summarizeTitle(s.title || "");
  title = clip(title, 28);
  var label = title + "  \u00b7  " + s.messages + (s.messages === 1 ? " msg" : " msgs");
  // Transcript weight, because agent.compact_threshold_bytes is measured in
  // exactly these bytes and compaction is otherwise invisible until it fires.
  if (typeof s.bytes === "number" && s.bytes > 0) label += "  \u00b7  " + fmtBytes(s.bytes);
  return label;
}

/* Conversations group by when they were last touched, because that is how
   you look for one: "the thing I was doing this morning", not an id. */
export function recencyGroup(updated) {
  if (!updated) return "Undated";
  var day = 24 * 60 * 60;
  var now = Math.floor(Date.now() / 1000);
  var age = now - updated;
  var rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  if (age < day && new Date(updated * 1000).toDateString() === new Date().toDateString()) return rtf.format(0, "day");
  if (age < 2 * day) return rtf.format(-1, "day");
  if (age < 7 * day) return "Previous 7 days";
  if (age < 30 * day) return "Previous 30 days";
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
  for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return h >>> 0;
}

export function peerColor(name) {
  return "hsl(" + (hashName(name || "") % 360) + " 35% 62%)";
}

export function parseCssColor(color) {
  var s = String(color || "").trim();
  var m = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i.exec(s);
  if (m) return [+m[1], +m[2], +m[3]];
  if (s.charAt(0) === "#") {
    var h = s.slice(1);
    if (h.length === 3) h = h.replace(/./g, function (c) { return c + c; });
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
  if (!ca || !cb) return a;
  var u = Math.max(0, Math.min(1, t));
  return "rgb(" + Math.round(ca[0] + (cb[0] - ca[0]) * u) + "," +
    Math.round(ca[1] + (cb[1] - ca[1]) * u) + "," +
    Math.round(ca[2] + (cb[2] - ca[2]) * u) + ")";
}

export function themeToken(name) {
  if (typeof document === "undefined" || !document.documentElement) return "";
  var v = (getComputedStyle(document.documentElement).getPropertyValue(name) || "").trim();
  var aliased = /^var\(\s*([--A-Za-z0-9_]+)\s*\)$/.exec(v);
  return aliased ? themeToken(aliased[1]) : v;
}


