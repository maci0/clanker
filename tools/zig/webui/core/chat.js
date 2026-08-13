// Pure DM/chat helpers — no DOM, no page state. Safe to import as ES module.
// dmPartner takes (room, instanceName) explicitly so it never closes over a mutable global.
export function dmSafeName(name) {
  return String(name).replace(/\|/g, "-");
}
export function dmRoom(a, b) {
  return "dm:" + [dmSafeName(a), dmSafeName(b)].sort().join("|");
}
export function dmPartner(room, instanceName) {
  if (!room || room.indexOf("dm:") !== 0) return dmSafeName(room);
  var parts = room.slice(3).split("|");
  var mine = dmSafeName(instanceName);
  for (var i = 0; i < parts.length; i++) if (parts[i] !== mine) return parts[i];
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
  if (!m) return "";
  if (m.id) return String(m.id);
  return "local:" + dmSafeName(m.from || "?") + ":" + (m.ts || 0) + ":" + strHash(String(m.text || ""));
}

/* djb2, the same shape `clankerMark` uses. Only ever compared against itself,
   so a collision needs the same sender, second and text — which is a message
   there is no way to tell apart anyway. */
function strHash(s) {
  var h = 5381;
  for (var i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}

export function hasServerId(m) {
  return !!(m && m.id);
}

export var CLANKER_MARKS = [
  "🐙", "🦊", "🦉", "🐢", "🦋", "🐝", "🦔", "🦦",
  "🦭", "🐬", "🦅", "🦩", "🐸", "🦎", "🐿️", "🦡",
  "🪼", "🦑", "🐳", "🦌", "🐺", "🦂", "🕷️", "🦜"
];
export function clankerMark(name) {
  var h = 5381;
  for (var i = 0; i < name.length; i++) h = ((h * 33) ^ name.charCodeAt(i)) >>> 0;
  return CLANKER_MARKS[h % CLANKER_MARKS.length];
}

