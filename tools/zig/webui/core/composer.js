// Vanilla, no bundler. Composer helpers — prompts, auto-grow, context meter.
export function loadPrompts() {
  try { return JSON.parse(window.localStorage.getItem("clanker.prompts") || "[]"); } catch (e) { return []; }
}

export function savePrompts(prompts) {
  try { window.localStorage.setItem("clanker.prompts", JSON.stringify(prompts)); } catch (e) {}
}

/* Removes a saved prompt by its exact text, and says whether it removed
   anything. The caller had `prompts.splice(prompts.indexOf(doomed), 1)`, which
   for a text that is not in the list is `splice(-1, 1)` — it deletes the *last*
   saved prompt and then persists that. The composer's suggestion popup is
   shared by three lists (saved prompts, `/` commands, `#` knowledge
   collections), so "the label under the cursor is one of your saved prompts"
   was never a safe assumption. */
export function forgetPrompt(prompts, text) {
  var at = prompts.indexOf(text);
  if (at === -1) return false;
  prompts.splice(at, 1);
  return true;
}

/* Moves the highlight inside a suggestion list that is already on screen.

   The `#` mention list had no way to move: the key handler only knew how to
   nudge `promptIndex` and re-render the *prompt* list, which for a value that
   does not start with `/` hides the popup outright — so the first arrow key
   dismissed the mentions instead of walking them. Re-rendering the mention
   list is not the answer either; it is built from a `/api/knowledge` fetch, and
   one request per arrow key is a request per arrow key. */
export function setActiveItem(listEl, index, taskEl) {
  var items = listEl.querySelectorAll(".palette-item");
  if (!items.length) return -1;
  var at = index;
  if (typeof at !== "number" || at < 0 || at >= items.length) at = 0;
  Array.prototype.forEach.call(items, function (li, i) {
    li.setAttribute("aria-selected", String(i === at));
  });
  if (taskEl) taskEl.setAttribute("aria-activedescendant", items[at].id || "");
  return at;
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
