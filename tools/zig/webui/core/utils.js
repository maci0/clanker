// Pure helpers — importable as ES module. No DOM, no `el`, no page state —
// anything here must be callable from another module or a node test without a
// page around it.
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

export function searchFold(value) {
  return String(value).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLocaleLowerCase();
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
  return new Intl.NumberFormat(undefined, {
    style: "currency", currency: "USD", minimumFractionDigits: 4, maximumFractionDigits: 4
  }).format(typeof n === "number" ? n : 0);
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
  if (diffDays === 0) return "today · " + dateStr;
  if (diffDays === 1) return "tomorrow · " + dateStr;
  if (diffDays === -1) return "yesterday · " + dateStr;
  if (diffDays > 1 && diffDays <= 7) return "in " + diffDays + " days · " + dateStr;
  if (diffDays < -1 && diffDays >= -7) return Math.abs(diffDays) + " days ago · " + dateStr;
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

export function sessionLabel(s) {
  var title = (s.title || "").replace(/\s+/g, " ").trim() || "(untitled)";
  title = clip(title, 56);
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
  if (age < day && new Date(updated * 1000).toDateString() === new Date().toDateString()) return "Today";
  if (age < 2 * day) return "Yesterday";
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


