// #session-status is `sr-only`: a message written only there announces to a
// screen reader and is invisible to everyone else, so a user who pressed
// Export, Save prompt, Compact or Remove workspace saw the button do nothing.
// `sessionNotice()` exists for exactly this — it toasts and falls back to the
// live region when there is no toast host — but most action call sites wrote
// `el.sessionStatus.textContent` directly, which is the bug wearing a comment
// that says the opposite two hundred lines above.
//
// The lines still allowed to write the live region are the ones a sighted user
// has already been shown something better for: the load chatter a view prints
// itself ("Loading conversation…", "Loaded N messages."), the sentence
// `restoreDraft()` appends to what the loader just wrote, the visible rail
// failure row #session-status mirrors for a screen reader, and
// `sessionNotice()`'s own fallback.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(here, "app.js"), "utf8");

// Every user-triggered action that answers in words. If one of these lines goes
// back to writing the live region alone, the button it belongs to is silent.
const ACTION_MESSAGES = [
  "Exported as JSON.",
  "Export failed: ",
  "Exported as Markdown.",
  "Nothing to export yet.",
  "Prompt saved.",
  "That prompt is already saved.",
  "Write the prompt in the composer first.",
  "Deleted that prompt.",
  "Compacted to ",
  "Compact failed: ",
  "Finish or stop the current run before compacting.",
  "Finish or stop the current run before switching conversation.",
  "This conversation has no saved turns yet.",
  "Moved to ",
  "Move failed: ",
  "Workspace ",
  "Could not create workspace: ",
  "Removed ",
  "Could not remove workspace: ",
  "Voice input failed: check microphone permission.",
  "The run ended before it finished",
  "Imported.",
  "Could not \" + verb",
];

function assignments(marker) {
  const out = [];
  let at = js.indexOf(marker);
  while (at >= 0) {
    const lineStart = js.lastIndexOf("\n", at) + 1;
    out.push(js.slice(lineStart, js.indexOf("\n", at)));
    at = js.indexOf(marker, at + 1);
  }
  return out;
}

test("sessionNotice is the visible channel and falls back to the live region", function () {
  assert.match(js, /function sessionNotice\(msg\) \{\n {2}if \(!uiToast\(msg\)\) el\.sessionStatus\.textContent = msg;/);
});

test("no user action answers in the sr-only live region alone", function () {
  const silent = [];
  for (const marker of ACTION_MESSAGES) {
    for (const line of assignments(marker)) {
      if (/el\.sessionStatus\.textContent/.test(line)) silent.push(line.trim());
    }
  }
  assert.deepEqual(silent, [], "these lines are invisible to a sighted user:\n" + silent.join("\n"));
});

test("sessionNotice is used at every action call site, not merely defined", function () {
  const uses = (js.match(/\bsessionNotice\(/g) || []).length;
  // One definition plus the app's own action sites: every answer the user
  // triggers has to arrive through here.
  assert.ok(uses >= 25, "expected every action to go through sessionNotice, saw " + uses);
});
