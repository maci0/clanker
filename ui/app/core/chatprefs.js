/* ---------- model and reasoning effort, per conversation ----------

   Which model a conversation runs on belongs to that conversation, not to the
   browser. The composer's two selects used to mirror into one global key each
   (`clanker.model`, `clanker.effort`), so changing the model while reading one
   chat silently changed what every other chat and every other tab sent on its
   next message, with nothing announcing it.

   Two layers, deliberately: the global keys stay as the *default a new chat
   starts from*, and this store holds the pin for a conversation that has one.
   A conversation is pinned when the reader changes a select while it is open,
   or when its first turn goes out on whatever was selected then — after which
   a later change elsewhere cannot move it.

   Shape and bounds mirror `drafts` in composer.js: one entry per session id,
   `at` stamped on every touch, and the `max_prefs` most recently touched kept
   so a long-lived browser cannot grow the key without limit. */
export var prefs_key = "clanker.chatprefs";
export var max_prefs = 50;

export function loadPrefs() {
  try {
    var raw = JSON.parse(window.localStorage.getItem(prefs_key) || "{}");
    return raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  } catch (e) { return {}; }
}

export function savePrefs(prefs) {
  try { window.localStorage.setItem(prefs_key, JSON.stringify(prefs || {})); } catch (e) {}
}

/* The pin for one conversation, or null when it has none — the caller's
   signal to fall back to the browser default rather than to blank selects. */
export function prefsFor(prefs, sessionId) {
  if (!prefs || !sessionId) return null;
  var p = prefs[sessionId];
  return p && typeof p === "object" ? p : null;
}

/* `patch` carries whichever of `model`/`effort` changed; the other is left
   as it was. An empty value unpins that field (the reader chose "config
   default"), and an entry with nothing left pinned is dropped rather than
   kept as an empty object that would read as a pin on `prefsFor`. */
export function setPref(prefs, sessionId, patch, now) {
  if (!prefs || !sessionId || !patch) return prefs;
  var p = prefs[sessionId] && typeof prefs[sessionId] === "object" ? prefs[sessionId] : {};
  ["model", "effort"].forEach(function (field) {
    if (!Object.prototype.hasOwnProperty.call(patch, field)) return;
    var v = patch[field] == null ? "" : String(patch[field]).trim();
    if (v) p[field] = v;
    else delete p[field];
  });
  if (!p.model && !p.effort) {
    delete prefs[sessionId];
    return prefs;
  }
  p.at = typeof now === "number" ? now : Date.now();
  prefs[sessionId] = p;
  var ids = Object.keys(prefs);
  if (ids.length > max_prefs) {
    ids.sort(function (a, b) { return (prefs[a].at || 0) - (prefs[b].at || 0); });
    ids.slice(0, ids.length - max_prefs).forEach(function (id) { delete prefs[id]; });
  }
  return prefs;
}

/* A deleted conversation leaves no pin behind: the id is gone from the server
   and a later one could only collide by accident. */
export function dropPref(prefs, sessionId) {
  if (!prefs || !sessionId) return prefs;
  delete prefs[sessionId];
  return prefs;
}

/* A fork, a branch or an import continues in a new id. The copy keeps running
   on what the conversation it came from was running on, and the two are
   separate entries from that point: editing one never moves the other. */
export function copyPref(prefs, fromId, toId, now) {
  var src = prefsFor(prefs, fromId);
  if (!src || !toId) return prefs;
  return setPref(prefs, toId, { model: src.model || "", effort: src.effort || "" }, now);
}

/* Which value a conversation actually runs on: its own pin when it has one,
   the browser default otherwise. The precedence lives here rather than in the
   picker because it is the whole rule this store exists for — a pinned chat
   ignores what another chat or another tab chose later. */
export function effectiveModel(pin, browserDefault) {
  return (pin && pin.model) || browserDefault || "";
}

export function effectiveEffort(pin, browserDefault) {
  return (pin && pin.effort) || browserDefault || "";
}
