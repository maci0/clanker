import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(dir, "arena.js"), "utf8");

test("a failed match open replaces the transcript, not just the status line", function () {
  assert.match(js, /showLoadError\(byId\("arena-transcript"\)/);
  assert.match(js, /fetchMatch\(id, false\)/);
  const fail = js.slice(js.indexOf("Could not load match:"));
  assert.match(fail, /arena-transcript/);
});

test("the running-match poll is not gated on a live topic nothing publishes", function () {
  // The tick used to open with `if (liveOk()) return;`, copied from the Fleet
  // floor. Fleet is right because `t:"mesh"` is really published; Arena copied
  // the guard without the publisher, and importing arena.js opens the
  // EventSource itself, so liveOk() was true from load and the poll never
  // fetched again. This reads both halves so the pair cannot drift apart
  // again: gate the poll on the stream only once something emits the topic.
  const live = readFileSync(join(dir, "..", "..", "..", "src", "serve", "live.zig"), "utf8");
  const hasPublisher = /publish\(\s*\.arena\b/.test(live);
  const gatesOnLive = /if \(liveOk\(\)\) return;/.test(js);
  assert.equal(
    gatesOnLive && !hasPublisher,
    false,
    "arena.js skips its poll while liveOk() is true, but src/serve/live.zig has no publish(.arena, ...) call, so nothing ever refreshes a running match"
  );
  // Whatever the answer above, the interval itself must still ask quietly.
  assert.match(js, /window\.setInterval\(function \(\) \{\s*fetchMatch\(state\.id, true\);/);
  assert.match(js, /ev\.t !== "arena"/);
});
