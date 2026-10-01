// `copyText` is the page's one copy path, and the label it settles on is the
// only thing a reader gets when the clipboard is not theirs to reach. A
// plain-http origin withholds the clipboard API, so that path is not an edge:
// it is every copy button on the page, every time.
//
// These cases run against the shipped function under the DOM stub the rest of
// the suite uses, so the fallback's own words are pinned rather than assumed.
import assert from "node:assert/strict";
import { test } from "bun:test";
import { copyText } from "./vendor.js";

function withDom(body, globals = {}) {
  var created = [];

  function makeNode(tag) {
    var node = {
      tagName: tag,
      textContent: "",
      value: "",
      className: "",
      children: [],
      attrs: {},
      setAttribute: function (k, v) { this.attrs[k] = v; },
      appendChild: function (c) { this.children.push(c); return c; },
      remove: function () { this.removed = true; },
      selectNodeContents: function () {},
    };

    created.push(node);
    return node;
  }

  var doc = {
    body: { appendChild: function (c) { created.push(c); return c; } },
    createElement: makeNode,
    // The shipped code reads `document.createRange`, not `window.document`'s.
    createRange: function () { return range; },
  };

  var range = { selectNodeContents: function () { this.target = arguments[0]; } };

  var selection = {
    removed: null,
    added: null,
    removeAllRanges: function () { this.removed = true; },
    addRange: function (r) { this.added = r; },
  };

  var timers = [];

  var win = Object.assign({
    setTimeout: function (fn) { timers.push(fn); return timers.length; },
    getSelection: function () { return selection; },
    document: doc,
    createRange: function () { return range; },
  }, globals);

  Object.defineProperty(win, "isSecureContext", { value: globals.secure !== false, writable: true });

  var previous = {
    document: globalThis.document,
    window: globalThis.window,
    navigator: globalThis.navigator,
  };

  globalThis.document = doc;
  globalThis.window = win;
  globalThis.navigator = win.navigator || {};

  var finish = body({ win: win, doc: doc, created: created, selection: selection, range: range, timers: timers });

  return Promise.resolve(finish).finally(function () {
    globalThis.document = previous.document;
    globalThis.window = previous.window;
    globalThis.navigator = previous.navigator;
  });
}

test("a copy with nothing to select still hands the reader the value", function () {
  withDom(function (env) {
    var btn = { textContent: "Share" };

    copyText("https://example.test/#chat?session=s1", btn, "Share", null);

    assert.equal(btn.textContent, "Selected: press Ctrl+C", "the label must offer a way onward, not a dead end");
    assert.ok(env.selection.added, "the value must be put on the clipboard path the reader can take");
    assert.ok(env.selection.removed, "a stale selection would replace the new one");
  });
});

test("the parked field is hidden from assistive tech and taken back off the page", function () {
  withDom(function (env) {
    var btn = { textContent: "Copy link" };

    copyText("https://example.test/#knowledge/k1", btn, "Copy link", null);

    var parked = env.created.find(function (n) { return n.className === "sr-only"; });

    assert.ok(parked, "a value with no visible node needs one to select");
    assert.equal(parked.value, "https://example.test/#knowledge/k1", "the field must hold the value, not a placeholder");
    assert.equal(parked.attrs["aria-hidden"], "true", "it is not content");
    assert.equal(parked.tabIndex, -1, "it must not take a tab stop from the reader");
    assert.ok(env.timers.length, "the field has to be reclaimed, or every copy leaks a node");

    env.timers.forEach(function (fn) { fn(); });

    assert.equal(parked.removed, true);
  });
});

test("a caller that already names a target keeps using it", function () {
  withDom(function (env) {
    var btn = { textContent: "Copy" };
    var target = { tagName: "PRE" };

    copyText("body text", btn, "Copy", target);

    assert.equal(env.range.target, target, "the caller's own node is the one selected");
    assert.equal(env.created.filter(function (n) { return n.className === "sr-only"; }).length, 0, "no second field is parked");
  });
});

test("a secure origin with a working clipboard still says Copied", async function () {
  var written = [];

  await withDom(async function (env) {
    var btn = { textContent: "Share" };

    Object.defineProperty(env.win, "isSecureContext", { value: true, writable: true });
    env.win.navigator = { clipboard: { writeText: function (t) { written.push(t); return Promise.resolve(); } } };
    globalThis.navigator = env.win.navigator;

    copyText("https://example.test/#chat", btn, "Share", null);

    await Promise.resolve();
    await Promise.resolve();

    assert.deepEqual(written, ["https://example.test/#chat"]);
    assert.equal(btn.textContent, "Copied", "the success label is the one the reader needs here");
  });
});
