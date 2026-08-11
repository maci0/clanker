// Vanilla, no bundler. Composer helpers — prompts, auto-grow, context meter.
export function loadPrompts() {
  try { return JSON.parse(window.localStorage.getItem("clanker.prompts") || "[]"); } catch (e) { return []; }
}

export function savePrompts(prompts) {
  try { window.localStorage.setItem("clanker.prompts", JSON.stringify(prompts)); } catch (e) {}
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
