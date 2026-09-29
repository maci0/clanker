// Search is a Work plugin that reads message text, not titles. The suite used
// to be nine substring assertions over app.js, which passed unchanged while
// every branch it names was free to be broken; it now mounts the shipped view
// over the DOM stub and drives the search, the length gate, the failure path
// and the stale-response guard the way the host does.
import test, { after, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { dispatch, installDom, serialize } from "../../app/lib/dom-stub.mjs";

const dir = dirname(fileURLToPath(import.meta.url));

const spec = readFileSync(join(dir, "plugin.json"), "utf8");

let restoreDom;

let view;

before(async function () {
  restoreDom = installDom();
  let registered = null;
  globalThis.clanker = { registerView (v) { registered = v; } };
  await import(join(dir, "app.js"));
  globalThis.clanker = undefined;
  assert.ok(registered, "app.js registers a view");
  view = registered;
});

after(function () { restoreDom(); });

// The host's `api` surface, with the three seams a test has to own: the
// element factory, the case-insensitive fold Search marks hits with, and the
// one HTTP call it makes.
function makeApi(opts) {
  opts = opts || {};
  const calls = { getJSON: [], opened: [], status: [] };

  const plural = function (n, forms) {
    return n + " " + (n === 1 ? forms.one : forms.other);
  };

  return {
    calls,
    el (tag, cls, text) {
      const el = document.createElement(tag);

      if (cls) { el.className = cls; }

      if (text !== null && text !== undefined) { el.textContent = text; }

      return el;
    },
    kit: { recordRow: { row: "row", head: "head", name: "name", snippet: "snippet", foot: "foot" } },
    fmt: { time () { return "then"; }, plural },
    status (msg) { calls.status.push(msg); },
    foldFind (text, needle, from) {
      const hay = text.toLowerCase();
      const at = hay.indexOf((needle || "").toLowerCase(), from || 0);

      if (at === -1) { return null; }

      return { start: at, end: at + needle.length, next: at + needle.length };
    },
    // Every answer goes through the recorder, so a test can count what the
    // view asked for even when it supplies its own transport.
    getJSON (url) {
      calls.getJSON.push(url);

      return opts.getJSON ? opts.getJSON(url) : Promise.resolve({ hits: [], truncated: false });
    },
    openSession (id, arg) { calls.opened.push({ id, arg }); },
  };
}

function mount(opts) {
  const api = makeApi(opts);
  const container = document.createElement("div");
  // mount() runs the view's own initial load, so the returned promise is part
  // of mounting and every test waits on it before it types.
  const ready = view.mount.call(view, container, api);

  return { api, container, ready };
}

function field(container) {
  return container.childNodes.flatMap(function () { return []; })
    .concat(recurse(container))
    .find(function (el) { return el.id === "search-q"; });
}

function recurse(el) {
  return (el.childNodes || []).reduce(function (acc, c) {
    acc.push(c);

    return acc.concat(recurse(c));
  }, []);
}

function results(container) {
  return recurse(container).find(function (el) { return el.id === "search-results"; });
}

function buttonByText(container, needle) {
  return recurse(container).find(function (el) {
    return el.tagName === "BUTTON" && serialize(el).indexOf(needle) >= 0;
  });
}

const HIT = {
  id: "sess-42",
  title: "cron spec drift",
  updated: 1700000000,
  role: "user",
  turn: 3,
  more: 2,
  snippet: "the cron spec refused the provider",
};

test("Search is a Work plugin that searches conversations", function () {
  assert.match(spec, /"name": "search"/);
  assert.match(spec, /"group": "Work"/);
});

test("a query under three characters asks for more instead of calling the host", async function () {
  const m = mount();
  await m.ready;
  const input = field(m.container);
  input.value = "  cr  ";
  await view.reload();
  assert.deepEqual(m.api.calls.getJSON, [], "two characters must not reach /api/sessions/search");
  assert.match(serialize(results(m.container)), /Type at least 3 characters/);
});

test("a long enough query searches the trimmed text and renders a hit", async function () {
  const m = mount({ getJSON () { return Promise.resolve({ hits: [HIT], truncated: false }); } });
  await m.ready;
  const input = field(m.container);
  input.value = "  cron spec  ";
  await view.reload();
  assert.deepEqual(m.api.calls.getJSON, ["/api/sessions/search?q=cron%20spec"]);
  const out = serialize(results(m.container));
  assert.match(out, /cron spec drift/, "the hit is listed by its title");
  assert.match(out, /the <mark>cron spec<\/mark> refused/, "the matched text is marked in the snippet");
  assert.match(out, /2 more matches here/, "a turn with more matches says so");
  assert.match(
    m.api.calls.status[m.api.calls.status.length - 1],
    /1 conversation\.$/,
    "the status line counts conversations with the singular form"
  );
});

test("a hit opens its conversation at the turn that matched", async function () {
  const m = mount({ getJSON () { return Promise.resolve({ hits: [HIT], truncated: false }); } });
  await m.ready;
  field(m.container).value = "cron spec";
  await view.reload();
  const row = buttonByText(results(m.container), "cron spec drift");
  assert.ok(row, "a hit renders as a button");
  assert.equal(row.getAttribute("aria-label"), "Open cron spec drift at turn 4");
  dispatch(row, "click");
  assert.deepEqual(m.api.calls.opened, [{ id: "sess-42", arg: { index: 3, query: "cron spec" } }]);
});

test("a truncated result says the list is the newest only", async function () {
  const m = mount({ getJSON () { return Promise.resolve({ hits: [HIT], truncated: true }); } });
  await m.ready;
  field(m.container).value = "cron spec";
  await view.reload();
  assert.match(m.api.calls.status[m.api.calls.status.length - 1], /showing the newest/);
});

test("a failed search says so and offers to run it again", async function () {
  let calls = 0;

  const m = mount({
    getJSON () {
      calls++;

      return calls === 1 ? Promise.reject(new Error("connection refused")) : Promise.resolve({ hits: [HIT] });
    },
  });

  await m.ready;
  field(m.container).value = "cron spec";
  await view.reload();
  const failed = serialize(results(m.container));
  assert.match(failed, /Search failed: connection refused/);
  assert.deepEqual(m.api.calls.getJSON.length, 1);
  const retry = buttonByText(results(m.container), "Try again");
  assert.ok(retry, "a failure offers a retry");
  dispatch(retry, "click");
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(m.api.calls.getJSON.length, 2, "the retry asks again");
});

test("no match says no conversation says it, and clearing empties the query", async function () {
  const m = mount({ getJSON () { return Promise.resolve({ hits: [] }); } });
  await m.ready;
  field(m.container).value = "cron spec";
  await view.reload();
  assert.match(serialize(results(m.container)), /No conversation says .cron spec./);
  const clear = buttonByText(results(m.container), "Clear search");
  assert.ok(clear, "an empty result offers to clear");
  dispatch(clear, "click");
  assert.equal(field(m.container).value, "", "clearing empties the field");
  assert.match(serialize(results(m.container)), /Type at least 3 characters/);
});

test("a slow answer that arrives after a newer query does not overwrite it", async function () {
  const pending = [];

  const m = mount({
    getJSON (url) {
      return new Promise(function (resolve) { pending.push({ url, resolve }); });
    },
  });

  await m.ready;
  const input = field(m.container);
  input.value = "first query";
  // The transport is held open, so these reloads are started, not awaited: the
  // promise the view hands back is the one waiting on the answer.
  view.reload();
  input.value = "second query";
  view.reload();
  assert.equal(pending.length, 2, "both queries were sent");
  // The first request answers last, which is the case a sequence number exists
  // for: without it the stale hits land under the newer query.
  pending[1].resolve({ hits: [HIT], truncated: false });
  await Promise.resolve();
  await Promise.resolve();
  assert.match(serialize(results(m.container)), /cron spec drift/);
  pending[0].resolve({ hits: [], truncated: false });
  await Promise.resolve();
  await Promise.resolve();
  assert.match(
    serialize(results(m.container)),
    /cron spec drift/,
    "the superseded empty answer must not clear the newer result"
  );
});

test("the button stays disabled until the query is long enough", async function () {
  const m = mount();
  await m.ready;
  const input = field(m.container);
  const go = recurse(m.container).find(function (el) { return el.id === "search-go"; });
  assert.ok(go, "the view has a search button");
  await view.reload();
  assert.equal(go.disabled, true, "an empty field cannot be searched");
  input.value = "cron spec";
  dispatch(input, "input");
  await Promise.resolve();
  assert.equal(go.disabled, false, "three characters is enough");
  input.value = "cr";
  dispatch(input, "input");
  assert.equal(go.disabled, true, "two characters is not");
});
