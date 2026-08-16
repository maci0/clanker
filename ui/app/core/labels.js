// Pure label formatters — no DOM, no page state, safe as ES module.
// Extracted so Runs, Fleet and System palette share one definition instead of
// each recomputing the same strings. Pure by construction: closes over nothing.

export function runLabel(r, clipFn) {
  var task = (r.task || "").replace(/\s+/g, " ").trim();
  if (typeof clipFn === "function") task = clipFn(task, 60);
  else if (task.length > 60) task = task.slice(0, 57) + "\u2026";
  return r.run_id + "  \u00b7  " + (task || "(no task)");
}

export function modelLabel(provider, model, providerCache) {
  var cache = providerCache || [];
  for (var i = 0; i < cache.length; i++) {
    if (cache[i].name !== provider) continue;
    var models = cache[i].models || [];
    for (var k = 0; k < models.length; k++) {
      if (models[k].name === model) return models[k].display || model;
    }
  }
  return model;
}

export function chatRoomLabel(room, isDmFn, dmPartnerFn, clankerMarkFn) {
  var r = room;
  if (typeof isDmFn === "function" && isDmFn(r.room)) {
    var who = typeof dmPartnerFn === "function" ? dmPartnerFn(r.room) : r.room;
    var mark = typeof clankerMarkFn === "function" ? clankerMarkFn(who) + " " : "";
    return mark + who;
  }
  return "# " + r.room;
}

// Manifest `category` keys, work-first then instance-ops. Keep in step with
// `src/toolhost/manifest.zig` `categories` and `tools/zig/tools.zig`.
export var toolCategoryOrder = ["code", "chat", "kanban", "agent", "knowledge", "web", "media", "compute", "transform", "harness"];

var toolCategoryLabels = {
  agent: "Agent",
  chat: "Chat",
  code: "Code",
  compute: "Compute",
  harness: "Harness",
  kanban: "Kanban",
  knowledge: "Knowledge",
  media: "Media",
  other: "Other",
  transform: "Transform",
  web: "Web"
};

export function toolCategoryLabel(cat) {
  var key = cat || "other";
  if (toolCategoryLabels[key]) return toolCategoryLabels[key];
  return key.charAt(0).toUpperCase() + key.slice(1);
}

export function compareToolCategories(a, b) {
  if (a === b) return 0;
  var ia = toolCategoryRank(a);
  var ib = toolCategoryRank(b);
  if (ia !== ib) return ia - ib;
  return a < b ? -1 : 1;
}

function toolCategoryRank(cat) {
  var key = cat || "other";
  if (key === "other") return toolCategoryOrder.length + 1;
  var i = toolCategoryOrder.indexOf(key);
  return i < 0 ? toolCategoryOrder.length : i;
}


