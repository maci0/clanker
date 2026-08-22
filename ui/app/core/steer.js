/* Mid-run steering ledger for the chat composer.

   Every steering message sent while a turn runs is recorded here with a
   state, so the row under the composer can list what was sent and where
   each message is, instead of one hint line that every send overwrote --
   N sends used to look exactly like one, which read as "my second message
   disappeared". The server was never the problem: POST /api/steer appends
   to a real FIFO (16 per run) that the agent loop drains between
   iterations. The client just kept no record of what it had sent.

   Pure module: no DOM access of its own, no fetch. app.js owns the wire
   and passes the document in for rendering, which keeps this testable
   under node with the dom stub. */

/* One entry per send. States:
     sending  -- POST in flight
     queued   -- server accepted it; it lands on the next model step
     applied  -- the run drained it into an LLM call (stream status event)
     failed   -- the POST was rejected; detail carries the reason */
export function makeSteerLedger() { return { entries: [] }; }

export function steerAdd(ledger, text) {
  var e = { text: String(text), state: "sending", detail: "" };
  ledger.entries.push(e);
  return e;
}

export function steerMark(entry, state, detail) {
  entry.state = state;
  entry.detail = detail || "";
}

/* The stream reports "steering message applied" with no id and no text,
   and the server drains oldest-first, so flip our oldest not-yet-applied
   entry. A still-`sending` entry can legitimately be the one that applied:
   the server can enqueue and drain it before its 200 reaches us. Returns
   null when nothing here matches -- a steer sent from another tab or from
   the goals view lands on the same session without an entry in this
   ledger. */
export function steerApplyOldest(ledger) {
  for (var i = 0; i < ledger.entries.length; i++) {
    var e = ledger.entries[i];
    if (e.state === "queued" || e.state === "sending") {
      e.state = "applied";
      return e;
    }
  }
  return null;
}

/* Entries the run never consumed. The server frees unpolled messages
   silently when the run ends (runRelease), so this ledger is the only
   place left that can say they were dropped. */
export function steerUnapplied(ledger) {
  return ledger.entries.filter(function (e) {
    return e.state === "queued" || e.state === "sending";
  });
}

export function steerClear(ledger) { ledger.entries.length = 0; }

export var steer_preview_max = 72;

export function steerPreview(text) {
  var t = String(text).replace(/\s+/g, " ").trim();
  if (t.length <= steer_preview_max) return t;
  return t.slice(0, steer_preview_max - 1) + "…";
}

export function steerStateLabel(entry) {
  if (entry.state === "sending") return "sending…";
  if (entry.state === "queued") return "queued";
  if (entry.state === "applied") return "applied";
  return "failed" + (entry.detail ? ": " + entry.detail : "");
}

/* Steered messages are persisted with this framing sentence prefixed, so a
   reloaded transcript can tell them apart from typed turns. Lockstep with
   the server (handleSteer in src/cli.zig) and the TUI (steerWhileRunning
   in src/tui/repl.zig); if the sentence drifts, detection fails soft --
   the message renders as a plain user turn, which is the old behaviour. */
export var steer_frame_sentence = "[The user interjected while this run was in progress; take the message into account and adjust course.]";

/* Null when the content is not a framed steering message; otherwise the
   user's own text with the framing stripped. */
export function steerFramedText(content) {
  var c = String(content);
  if (c.slice(0, steer_frame_sentence.length) !== steer_frame_sentence) return null;
  return c.slice(steer_frame_sentence.length).replace(/^\s+/, "");
}

/* The user's own words when this transcript message was interjected mid-run,
   null when it was a typed turn.

   The server marks it: `steered:true` on the message, with `content` holding
   what the user actually typed. Transcripts saved before that flag existed
   carry the framing sentence inside the content instead, which is what the
   fallback reads -- so an old conversation keeps rendering its interjections
   as interjections. */
export function steeredText(message) {
  if (!message) return null;
  if (message.steered) return String(message.content == null ? "" : message.content);
  return steerFramedText(message.content == null ? "" : message.content);
}

/* Rebuild the visible list. A full rebuild is cheap: the server caps the
   queue at 16 messages per run, so there is nothing worth diffing. */
export function renderSteerList(ledger, listEl, doc) {
  var d = doc || (typeof document !== "undefined" ? document : null);
  if (!listEl || !d) return;
  listEl.textContent = "";
  for (var i = 0; i < ledger.entries.length; i++) {
    var e = ledger.entries[i];
    var li = d.createElement("li");
    li.setAttribute("data-state", e.state);
    li.textContent = steerStateLabel(e) + " · " + steerPreview(e.text);
    listEl.appendChild(li);
  }
}
