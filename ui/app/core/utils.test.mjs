import assert from "node:assert/strict";
import test from "node:test";
import { callableProviders, providerUnusableReason } from "./utils.js";

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
