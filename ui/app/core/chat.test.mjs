// The Chat search box is fed by an HTTP call, so it is the one search in the
// page that can answer out of order: the input handler debounces, a second
// query is sent before the first comes back, and the first answer then lands
// on top of the second. Nothing said which query the panel was showing, so the
// reader saw "3 matches" for a phrase they had already replaced.
//
// These are the shipped Chat search helpers, against the endpoint's answer
// shape (`{ hits: [...] }`).
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chatMessageSearch } from "./chat.js";

function msgs() {
  return [
    { id: "a", from: "ada", text: "the cron spec is a fix" },
    { id: "b", from: "bo", text: "provider refused the request" },
    { id: "c", from: "ada", text: "nothing to see" },
    { id: "d", from: "cy", text: "a second fix, and another" },
  ];
}

test("a search answers the newest query when an older one lands last", function () {
  var search = chatMessageSearch();
  var pending = [];

  search.fetch = function (q) {
    return new Promise(function (resolve) { pending.push({ q: q, resolve: resolve }); });
  };

  // "fix" then "second", the second answered first, the first after.
  var first = search.run("fix", msgs());
  var second = search.run("second", msgs());

  // `fetch` is reached on a microtask, so both requests exist after a tick.
  return Promise.resolve().then(function () {
    assert.equal(pending.length, 2, "both queries are in flight at once");
    pending[1].resolve({ hits: [{ id: "d", from: "cy", text: "a second fix, and another" }] });

    return second;
  }).then(function (secondState) {
    assert.equal(secondState.status, "done");
    assert.equal(secondState.query, "second");
    assert.deepEqual(secondState.hits.map(function (h) { return h.id; }), ["d"]);

    pending[0].resolve({ hits: [{ id: "a", from: "ada", text: "the cron spec is a fix" }] });

    return first;
  }).then(function (firstState) {
    assert.equal(firstState.status, "stale", "the superseded answer must be dropped, not shown");
    assert.deepEqual(firstState.hits, []);
  });
});

test("a failed first search does not make the next one stale", function () {
  var search = chatMessageSearch();
  var answers = [Promise.reject(new Error("host is down")), Promise.resolve({ hits: [{ id: "a" }] })];

  search.fetch = function () { return answers.shift(); };

  return search.run("fix", msgs()).then(function (failed) {
    assert.equal(failed.status, "error");
    assert.match(failed.error, /host is down/);
    assert.deepEqual(failed.hits, []);

    return search.run("fix", msgs()).then(function (recovered) {
      assert.equal(recovered.status, "done");
      assert.deepEqual(recovered.hits.map(function (h) { return h.id; }), ["a"]);
    });
  });
});

test("an emptied query clears the panel instead of searching for nothing", function () {
  var search = chatMessageSearch();

  search.fetch = function () { throw new Error("an empty query must not reach the host"); };

  return search.run("   ", msgs()).then(function (state) {
    assert.equal(state.status, "cleared");
    assert.deepEqual(state.hits, []);
  });
});

test("a short query still answers, and an empty answer is named as such", function () {
  var search = chatMessageSearch();

  search.fetch = function () { return Promise.resolve({ hits: [] }); };

  return search.run("q", msgs()).then(function (state) {
    assert.equal(state.status, "done");
    assert.equal(state.query, "q");
    assert.deepEqual(state.hits, []);
  });
});

test("the in-flight state names the query so an empty panel is answerable", function () {
  var search = chatMessageSearch();

  search.fetch = function () { return Promise.resolve({ hits: [] }); };

  var inflight = search.pending("  fix  ");

  assert.equal(inflight.status, "searching");
  assert.equal(inflight.query, "fix");
  assert.deepEqual(inflight.hits, []);

  return search.run("fix", msgs());
});

test("the page's search box draws the guarded state, not its own answer", async function () {
  // The helper is only worth anything if the box goes through it. Pinned
  // because the wiring is a hand edit in a 5,700-line module, and a guard a
  // later edit routes around is invisible in a diff of the panel's markup.
  var text = await readFile(new URL("../app.js", import.meta.url), "utf8");

  assert.match(text, /chatMessageSearch/u, "app.js must import the guarded search");
  assert.match(
    text,
    /chatSearch\.run\(q\)\.then\(drawChatSearchState\)/u,
    "the box must draw the state the guarded run resolves",
  );
  assert.match(
    text,
    /if \(state\.status === "stale"\) \{ return; \}/u,
    "a superseded answer must never reach the panel",
  );
  assert.match(text, /"Searching “" \+ state\.query/u, "the panel must say it is working, and for what");
});
