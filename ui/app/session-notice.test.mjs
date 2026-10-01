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
const html = readFileSync(join(here, "index.html"), "utf8");

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

// The mirror is the app's whole answer channel for a built-in view, so a live
// region left off it is silent by construction: the Models view's Live and
// Discover panels write their success and failure lines to #models-live-status
// and #models-catalog-status, and nothing watched either, so a listing that
// failed said so to a screen reader alone.
test("every sr-only live region in the page is mirrored to a visible toast", function () {
  const live = [];

  for (const m of html.matchAll(/<[a-z]+ class="[^"]*\bsr-only\b[^"]*"[^>]*\bid="([a-z0-9-]+)"[^>]*aria-live/g)) {
    live.push(m[1]);
  }

  assert.ok(live.length >= 10, "expected the views' live regions to be found, saw " + live.length);
  // The selector above is what mirrors them, so what has to hold here is that
  // it matches the same shape of element this scan does.
  // The mirror walks the markup rather than keeping an id list, so the two
  // cannot drift; this asserts it still does, and that the one exemption is
  // still named and still is the only one.
  const sel = js.slice(js.indexOf("Derived from the markup")).match(/querySelectorAll\("([^"]+)"\)/);
  assert.ok(sel, "the mirror must derive its regions from the markup, not a hand-kept list");
  const exempt = [];

  for (const m of sel[1].matchAll(/:not\(#([a-z0-9-]+)\)/g)) { exempt.push(m[1]); }

  assert.deepEqual(exempt, ["arena-status"],
    "features/arena.js rewrites #arena-status every poll tick; mirroring it would toast every round");
  // The scan has to be finding the regions that were being missed, or the
  // assertion above would pass on an empty page.
  assert.equal(live.indexOf("models-live-status") !== -1, true);
  assert.equal(live.indexOf("models-catalog-status") !== -1, true);

});

// The exemption above is only sound while the arena view keeps its own failures
// visible. Without these, a match whose poll gave up or whose 3D stage fell back
// froze on screen in silence, with the region the only record.
test("the arena view toasts the failures it withholds from the mirror", function () {
  const arena = readFileSync(join(here, "features", "arena.js"), "utf8");

  for (const needle of ["Lost track of match", "Could not load match", "Could not load matches", "3D stage unavailable"]) {
    assert.ok(arena.includes(needle), "the arena view no longer says " + needle);
  }

  assert.match(arena, /function arenaToast\(msg\) \{[\s\S]*?toast\(msg\);/,
    "the arena's own messages must reach the visible toast host");
});
