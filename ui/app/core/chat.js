// Pure DM/chat helpers — no DOM, no page state. Safe to import as ES module.
// dmPartner takes (room, instanceName) explicitly so it never closes over a mutable global.
function dmSafeName(name) {
  return String(name).replace(/\|/g, "-");
}

export function dmRoom(a, b) {
  return "dm:" + [dmSafeName(a), dmSafeName(b)].sort().join("|");
}

export function dmPartner(room, instanceName) {
  if (!room || room.indexOf("dm:") !== 0) { return dmSafeName(room); }

  var parts = room.slice(3).split("|");
  var mine = dmSafeName(instanceName);

  for (var i = 0; i < parts.length; i++) { if (parts[i] !== mine) { return parts[i]; } }

  return parts[parts.length - 1] || room;
}

export function isDm(room) {
  return typeof room === "string" && room.indexOf("dm:") === 0;
}

/* A message's identity, for the page's own bookkeeping — the seen-set that
   dedupes poll batches, and the key a local thread hangs off.

   `id` is not guaranteed. `chatrooms.zig` defaults `Message.id` to `""` and
   documents the case ("a peer too old to send one"), and `receive` accepts
   such a message rather than dropping it. The page took the id on faith: the
   seen-set keyed on `m.id`, so the first id-less message registered `""` and
   every later one was then discarded as already seen, and the thread key read
   `m.id || msgKey` against an identifier that does not exist anywhere in the
   file — a ReferenceError that aborted the render mid-batch, losing the rest
   of the batch with it while the room reported a network error.

   The fallback is derived from what an id-less message does carry. It is not a
   server id and is never sent as one: the room actions that name a message to
   the server (pin, edit, delete, react) still need a real `id`, and
   `hasServerId` is what asks. */
export function messageKey(m) {
  if (!m) { return ""; }

  if (m.id) { return String(m.id); }

  return "local:" + dmSafeName(m.from || "?") + ":" + (m.ts || 0) + ":" + strHash(String(m.text || ""));
}

/* djb2, the same shape `clankerMark` uses. Only ever compared against itself,
   so a collision needs the same sender, second and text — which is a message
   there is no way to tell apart anyway. */
function strHash(s) {
  var h = 5381;

  for (var i = 0; i < s.length; i++) { h = ((h * 33) ^ s.charCodeAt(i)) >>> 0; }

  return h.toString(36);
}

export function hasServerId(m) {
  return !!(m && m.id);
}

var CLANKER_MARKS = [
  "🐙", "🦊", "🦉", "🐢", "🦋", "🐝", "🦔", "🦦",
  "🦭", "🐬", "🦅", "🦩", "🐸", "🦎", "🐿️", "🦡",
  "🪼", "🦑", "🐳", "🦌", "🐺", "🦂", "🕷️", "🦜"
];

export function clankerMark(name) {
  var h = 5381;

  for (var i = 0; i < name.length; i++) { h = ((h * 33) ^ name.charCodeAt(i)) >>> 0; }

  return CLANKER_MARKS[h % CLANKER_MARKS.length];
}
/* The Chat search box is the one search on the page that answers over HTTP,
   so it is the one that can answer out of order: the input handler
   debounces, a second query is sent before the first returns, and the first
   answer then lands on top of the second.

   A counter decides which answer is allowed to paint, and every state names
   the query it belongs to, so an empty panel is answerable: no query yet is
   a search that has not started, and a query that found nothing is a search
   that finished.

   `fetch` is the seam: the host assigns the real request, a test the deferred
   one it needs to answer out of order. No DOM and no page state otherwise. */

/**
 * @typedef {{ id?: string, from?: string, text?: string }} ChatSearchHit
 * @typedef {"searching" | "cleared" | "done" | "stale" | "error"} ChatSearchStatus
 * @typedef {{ status: ChatSearchStatus, query: string, hits: ChatSearchHit[], error?: string }} ChatSearchState
 * @typedef {(query: string, messages: unknown[]) => Promise<{ hits?: ChatSearchHit[] }>} ChatSearchFetch
 */

/** @param {unknown} reason What a failed fetch rejected with. */
const chatFetchErrorText = (reason) => (reason instanceof Error && reason.message !== "" ? reason.message : String(reason)),

  chatMessageSearch = () => {
    let seq = 0;

    return {
      /** @type {ChatSearchFetch} Assigned by the caller, and per test to control answer order. */
      fetch: () => Promise.resolve({ hits: [] }),

      /**
       * The state drawn from the moment of the press, so the panel can say it
       * is working before the answer lands.
       * @param {string} raw The query as typed.
       * @returns {ChatSearchState} A `searching` state naming the trimmed query.
       */
      pending: (raw) => ({ status: "searching", query: raw.trim(), hits: [] }),

      /**
       * Resolves to the state the panel should draw: `done` or `error` for the
       * answer that is still current, `stale` for one a later query superseded.
       * Never rejects: a failed search is a state the panel says out loud.
       * @param {string} raw The query as typed; blank clears the panel.
       * @param {unknown[]} [messages] Passed through to `fetch`.
       * @returns {Promise<ChatSearchState>} The state for this query.
       */
      async run(raw, messages = []) {
        seq += 1;

        /* A blank query fetches nothing and leaves `outcome` undefined. A fetch
           is settled rather than awaited, so one that throws synchronously or
           rejects becomes the `error` state instead of a rejection. */
        const mine = seq,
          query = raw.trim(),
          [outcome] = query === "" ? [] : await Promise.allSettled([Promise.resolve().then(() => this.fetch(query, messages))]);

        if (outcome === undefined) { return { status: "cleared", query, hits: [] }; }

        if (mine !== seq) { return { status: "stale", query, hits: [] }; }

        if (outcome.status === "rejected") {
          return { status: "error", query, hits: [], error: chatFetchErrorText(outcome.reason) };
        }

        return { status: "done", query, hits: outcome.value.hits ?? [] };
      },
    };
  };

export { chatMessageSearch };
