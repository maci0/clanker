// Vanilla, no bundler. Composer helpers — prompts, auto-grow, context meter.
export function loadPrompts() {
  try { return JSON.parse(window.localStorage.getItem("clanker.prompts") || "[]"); } catch (e) { return []; }
}

export function savePrompts(prompts) {
  try { window.localStorage.setItem("clanker.prompts", JSON.stringify(prompts)); } catch (e) {}
}

/* ---------- unsent drafts, per conversation ----------

   A half-written task in the composer had no owner. Reloading the page, or
   switching to another conversation and back, threw it away — and switching is
   exactly what you do when a question needs something you have to go and look
   up. The text was already the one thing on the page with no home: the
   transcript is on the server, the model, theme, view and selected knowledge
   are all in localStorage, and the thing you were in the middle of writing was
   not.

   Kept in one key rather than one key per conversation, because a browser
   profile that has seen a thousand conversations should not carry a thousand
   entries: `setDraft` bounds the store to the `max_drafts` most recently
   touched and drops the rest. A draft is the composer's business only — it is
   never sent, and clearing it is what a finished run does. */
export var drafts_key = "clanker.drafts";
export var max_drafts = 20;

export function loadDrafts() {
  try {
    var raw = JSON.parse(window.localStorage.getItem(drafts_key) || "{}");
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
    return raw;
  } catch (e) { return {}; }
}

export function saveDrafts(drafts) {
  try { window.localStorage.setItem(drafts_key, JSON.stringify(drafts || {})); } catch (e) {}
}

export function draftFor(drafts, sessionId) {
  if (!drafts || !sessionId) return "";
  var d = drafts[sessionId];
  return d && typeof d.text === "string" ? d.text : "";
}

/* Whitespace is not a draft: an empty box, or one holding a stray newline,
   deletes the entry rather than storing it, so restoring never replaces a
   cleared composer with blanks. `now` is injectable for the same reason the
   eviction is testable at all. */
export function setDraft(drafts, sessionId, text, now) {
  if (!drafts || !sessionId) return drafts;
  if (!text || !String(text).trim()) {
    delete drafts[sessionId];
    return drafts;
  }
  drafts[sessionId] = { text: String(text), at: typeof now === "number" ? now : Date.now() };
  var ids = Object.keys(drafts);
  if (ids.length > max_drafts) {
    ids.sort(function (a, b) { return (drafts[a].at || 0) - (drafts[b].at || 0); });
    ids.slice(0, ids.length - max_drafts).forEach(function (id) { delete drafts[id]; });
  }
  return drafts;
}

export function promptQuery(taskValue) {
  if (!taskValue || taskValue.charAt(0) !== "/") return null;
  return taskValue.slice(1).toLowerCase();
}

export function autoGrow(textarea) {
  textarea.style.height = "auto";
  var cap = Math.round(window.innerHeight / 3);
  textarea.style.height = Math.min(textarea.scrollHeight, cap) + "px";
}

export function contextLabel(meta, providerCache, modelSelectValue, fmtBytes) {
  if (!meta || typeof meta.bytes !== "number" || !meta.bytes) return "";
  var pair = (modelSelectValue || "").split(" ");
  var window_ = 0;
  (providerCache || []).forEach(function (prov) {
    if (prov.name !== pair[0]) return;
    (prov.models || []).forEach(function (m) { if (m.name === pair[1]) window_ = m.context_window || 0; });
  });
  if (!window_) return fmtBytes(meta.bytes) + " of history";
  var pct = Math.round((meta.bytes / 4) / window_ * 100);
  return fmtBytes(meta.bytes) + " · about " + pct + "% of context";
}

export function transcriptMarkdown(transcriptEl, currentSessionMeta, sessionId) {
  var meta = currentSessionMeta();
  var lines = ["# " + ((meta && meta.title) || "clanker conversation"), "", "`" + sessionId + "`", ""];
  transcriptEl.querySelectorAll(".turn").forEach(function (turn) {
    var task = turn.querySelector(".turn-you");
    var answer = turn.querySelector(".turn-answer");
    if (task) {
      var author = task.querySelector(".turn-author");
      var said = author ? task.textContent.slice(author.textContent.length) : task.textContent;
      lines.push("## " + said.trim(), "");
    }
    var body = turn.markdownSource || (answer ? answer.textContent : "");
    if (body) lines.push(body.replace(/\s+$/, ""), "");
  });
  return lines.join("\n");
}

export function downloadText(name, text, mime) {
  var blob = new Blob([text], { type: mime });
  var url = URL.createObjectURL(blob);
  var a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  window.setTimeout(function () { URL.revokeObjectURL(url); }, 0);
}
