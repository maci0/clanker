// Pure DM/chat helpers extracted from app.js.
// No DOM, no `el`, no page state — safe to import as ES module.
// dmPartner takes (room, instanceName) explicitly so it never closes over
// a mutable global; the window bridge curries the global for classic app.js.
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
if (typeof window !== "undefined") window.ckChat = {
  dmSafeName: dmSafeName,
  dmRoom: dmRoom,
  dmPartner: function (room) { return dmPartner(room, window.instanceName || ""); },
  isDm: isDm,
  CLANKER_MARKS: CLANKER_MARKS,
  clankerMark: clankerMark,
};
