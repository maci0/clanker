import assert from "node:assert/strict";
import test from "node:test";
import { callableProviders, providerUnusableReason, readJson, classifyLoadFailure } from "./utils.js";

// The availability contract of GET /api/providers: rows the server marked
// `usable:false` stay in the payload (the Models view is inventory) but the
// chat picker and the fallback select build only from the callable set. The
// server side of the same contract is pinned in cli.zig's
// annotateProviderUsability tests; this half pins what the page does with it.

const payload = [
  { name: "anthropic", usable: false, reason: "ANTHROPIC_API_KEY not set" },
  { name: "deepseek", usable: true },
  { name: "legacy-no-field" },
];

test("the picker set omits providers the server cannot call", function () {
  const callable = callableProviders(payload).map(function (p) { return p.name; });
  assert.deepEqual(callable, ["deepseek", "legacy-no-field"]);
});

test("a row without the usable field counts as callable (older server)", function () {
  assert.equal(callableProviders([{ name: "old" }]).length, 1);
});

test("empty and missing lists stay empty rather than throwing", function () {
  assert.deepEqual(callableProviders(null), []);
  assert.deepEqual(callableProviders([]), []);
});

test("the inventory reason is the server's, with a fallback label", function () {
  assert.equal(providerUnusableReason(payload[0]), "ANTHROPIC_API_KEY not set");
  assert.equal(providerUnusableReason({ name: "x", usable: false }), "not configured");
  assert.equal(providerUnusableReason(payload[1]), "");
  assert.equal(providerUnusableReason(payload[2]), "");
});

// A list load fails in two shapes the page must not confuse: a module the
// operator switched off (the route answers 404 with its own reason, a settled
// state) and a request that never got an answer (retryable). loadSessions used
// to fold both into an empty list, so a dead server read as "no conversations
// yet" — docs/reports/bugs/2026-08-22-webui-loadsessions-swallows-failure.md.

test("readJson carries the status onto the error it throws", async function () {
  const res = {
    ok: false,
    status: 404,
    json: function () { return Promise.resolve({ ok: false, error: "sessions module disabled" }); },
  };
  await assert.rejects(readJson(res), function (err) {
    assert.equal(err.message, "sessions module disabled");
    assert.equal(err.status, 404);
    return true;
  });
});

test("readJson carries the status even when the body is not JSON", async function () {
  const res = {
    ok: false,
    status: 502,
    json: function () { return Promise.reject(new Error("not json")); },
  };
  await assert.rejects(readJson(res), function (err) {
    assert.equal(err.status, 502);
    return true;
  });
});

test("a switched-off module is a settled state, not a retryable failure", function () {
  const err = new Error("sessions module disabled");
  err.status = 404;
  const out = classifyLoadFailure(err);
  assert.equal(out.kind, "disabled");
  assert.equal(out.retry, false);
  assert.equal(out.message, "sessions module disabled");
});

test("a 404 that is not a disabled module stays retryable", function () {
  const err = new Error("no such session");
  err.status = 404;
  const out = classifyLoadFailure(err);
  assert.equal(out.kind, "failed");
  assert.equal(out.retry, true);
  assert.equal(out.message, "no such session");
});

test("a server error is retryable and keeps the server's own words", function () {
  const err = new Error("HTTP 500");
  err.status = 500;
  const out = classifyLoadFailure(err);
  assert.equal(out.kind, "failed");
  assert.equal(out.retry, true);
  assert.equal(out.message, "HTTP 500");
});

test("a fetch that never reached the server describes itself", function () {
  const out = classifyLoadFailure(new TypeError("Failed to fetch"));
  assert.equal(out.kind, "failed");
  assert.equal(out.retry, true);
  assert.equal(out.message, "Could not reach the server.");
});

test("a failure with no message at all still says something", function () {
  const out = classifyLoadFailure(null);
  assert.equal(out.kind, "failed");
  assert.equal(out.message, "Could not reach the server.");
});
