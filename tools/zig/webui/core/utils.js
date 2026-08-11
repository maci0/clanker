// Pure helpers extracted from app.js — importable as ES module, no side effects.
export function fmtBytes(n) {
  if (n < 1024) return n + " B";
  if (n < 1024 * 1024) return Math.round(n / 1024) + " KB";
  return (n / (1024 * 1024)).toFixed(1) + " MB";
}

export function clip(text, max) {
  if (text.length <= max) return text;
  var cut = text.slice(0, max);
  var space = cut.lastIndexOf(" ");
  return (space > max * 0.6 ? cut.slice(0, space) : cut).replace(/[\s,;:.\-]+$/, "") + "\u2026";
}

export function fuzzyMatch(query, text) {
  if (!query) return true;
  var t = String(text).toLowerCase();
  var q = String(query).toLowerCase();
  var qi = 0;
  for (var i = 0; i < t.length && qi < q.length; i++) {
    if (t.charAt(i) === q.charAt(qi)) qi += 1;
  }
  return qi === q.length;
}

export function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, function (c) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
  });
}

export function fmtMs(ms) {
  if (ms < 1000) return ms + "ms";
  return (ms / 1000).toFixed(1) + "s";
}
