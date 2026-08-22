// The steering ledger exists because N sends used to be indistinguishable
// from one: the chat composer kept no record of what it had steered, so a
// second message visibly "disappeared" the first. These tests pin the
// ledger's ordering, state transitions, and the framed-transcript
// detection against the server's persisted shape.
import test from "node:test";
import assert from "node:assert/strict";
import { serialize } from "../lib/dom-stub.mjs";
import {
  makeSteerLedger, steerAdd, steerMark, steerApplyOldest, steerUnapplied,
  steerClear, steerPreview, steerStateLabel, steerFramedText, steeredText,
  steer_frame_sentence, steer_preview_max, renderSteerList,
} from "./steer.js";

test("two sends are two entries, in order — nothing overwrites", function () {
  const l = makeSteerLedger();
  steerAdd(l, "first course correction");
  steerAdd(l, "second course correction");
  assert.equal(l.entries.length, 2);
  assert.equal(l.entries[0].text, "first course correction");
  assert.equal(l.entries[1].text, "second course correction");
  assert.equal(l.entries[0].state, "sending");
});

test("applied events flip oldest-first, matching the server's FIFO drain", function () {
  const l = makeSteerLedger();
  const a = steerAdd(l, "a");
  const b = steerAdd(l, "b");
  steerMark(a, "queued");
  steerMark(b, "queued");
  assert.equal(steerApplyOldest(l), a);
  assert.equal(a.state, "applied");
  assert.equal(steerApplyOldest(l), b);
  assert.equal(steerApplyOldest(l), null, "a third event has nothing left to flip");
});

test("a still-sending entry can be the one that applied (event beats the 200)", function () {
  const l = makeSteerLedger();
  const a = steerAdd(l, "a");
  assert.equal(steerApplyOldest(l), a);
  // The late 200 must not demote it back to queued; app.js guards on state.
  assert.equal(a.state, "applied");
});

test("failed entries are skipped by apply and excluded from unapplied", function () {
  const l = makeSteerLedger();
  const bad = steerAdd(l, "rejected");
  const ok = steerAdd(l, "accepted");
  steerMark(bad, "failed", "HTTP 429");
  steerMark(ok, "queued");
  assert.equal(steerApplyOldest(l), ok);
  assert.deepEqual(steerUnapplied(l), []);
  assert.equal(steerStateLabel(bad), "failed: HTTP 429");
});

test("unapplied lists what the run-end note must report, then clear empties", function () {
  const l = makeSteerLedger();
  const a = steerAdd(l, "consumed");
  steerAdd(l, "never consumed");
  steerMark(a, "queued");
  steerApplyOldest(l);
  const dropped = steerUnapplied(l);
  assert.equal(dropped.length, 1);
  assert.equal(dropped[0].text, "never consumed");
  steerClear(l);
  assert.equal(l.entries.length, 0);
});

test("preview folds whitespace and clips long text", function () {
  assert.equal(steerPreview("  keep \n it \t short  "), "keep it short");
  const long = "x".repeat(steer_preview_max + 20);
  const p = steerPreview(long);
  assert.equal(p.length, steer_preview_max);
  assert.ok(p.endsWith("…"));
});

test("framed transcript messages are detected and stripped; plain ones are not", function () {
  const framed = steer_frame_sentence + "\n\nplease stop and summarize";
  assert.equal(steerFramedText(framed), "please stop and summarize");
  assert.equal(steerFramedText("please stop and summarize"), null);
  assert.equal(steerFramedText(""), null);
});

test("a steered turn is read from the flag, and from the framing on old transcripts", function () {
  // What the server stores now: the user's own words plus the marker.
  assert.equal(steeredText({ role: "user", content: "cite the source", steered: true }), "cite the source");
  // What transcripts written before the marker hold.
  const framed = steer_frame_sentence + "\n\ncite the source";
  assert.equal(steeredText({ role: "user", content: framed }), "cite the source");
  // A typed turn is neither.
  assert.equal(steeredText({ role: "user", content: "cite the source" }), null);
  assert.equal(steeredText(null), null);
});

test("renderSteerList rebuilds one li per entry with its state", function () {
  const l = makeSteerLedger();
  steerMark(steerAdd(l, "first"), "applied");
  steerMark(steerAdd(l, "second"), "queued");
  const list = document.createElement("ul");
  renderSteerList(l, list, document);
  assert.equal(list.childNodes.length, 2);
  assert.equal(list.childNodes[0].getAttribute("data-state"), "applied");
  assert.equal(list.childNodes[1].getAttribute("data-state"), "queued");
  assert.ok(serialize(list).includes("queued · second"));
  // A repaint replaces, never accumulates.
  renderSteerList(l, list, document);
  assert.equal(list.childNodes.length, 2);
});
