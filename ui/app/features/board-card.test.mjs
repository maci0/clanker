// A board card is a `<button>`. Its hover actions — Open card, Move to next
// column — used to be appended *into* that button, and so did a quick-edit
// pencil that duplicated the first of them.
//
// Two things were wrong with that:
//
//   * A button's children are presentational in ARIA, so the accessibility
//     tree flattened both controls away and there was no way to reach them at
//     all; nesting interactive content inside a button is also invalid HTML.
//     axe reported it as `nested-interactive`, logged as a handoff item in the
//     2026-08-12 sweep in docs/reviews/webui.md and still listed under
//     "Left / next".
//   * `.card-quick-edit-btn` (28px at `top:4px right:4px`) sat entirely inside
//     `.card-quick-actions` (58×30 at `top:2px right:2px`), at the same
//     `z-index`, later in DOM order — so the actions bar painted over it and
//     the pencil could never be clicked. It ran the same code as the bar's own
//     Open card button, so nothing was lost by deleting it.
//
// The actions are now a sibling of the card button inside the card's own
// `<li>`, which is the positioning context.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const js = readFileSync(join(here, "board.js"), "utf8");
const css = readFileSync(join(here, "..", "app.css"), "utf8");

function elem(tag) {
  const e = {
    tagName: (tag || "").toUpperCase(),
    className: "",
    title: "",
    childNodes: [],
    attrs: {},
    listeners: {},
    appendChild(c) { this.childNodes.push(c); return c; },
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    addEventListener(t, f) { this.listeners[t] = f; },
  };
  return e;
}

// `cardQuickActions` is a top-level function in board.js, which imports the
// whole /webui module graph; the same lift-and-run harness `arena.test.mjs`
// uses for `ensure3d` runs it verbatim over stubs.
function harness() {
  const from = js.indexOf("function cardQuickActions(c) {");
  assert.ok(from >= 0, "cardQuickActions is a top-level function in board.js");
  const to = js.indexOf("\nfunction showDropIndicator(", from);
  assert.ok(to > from, "cardQuickActions still precedes showDropIndicator");

  const ctx = {
    document: { createElement: elem },
    icon: (name) => { const i = elem("svg"); i.attrs["data-icon"] = name; return i; },
    openCardId: null,
    renders: 0,
    posts: [],
    board: { columns: [{ id: "todo", title: "To do" }, { id: "doing", title: "Doing" }] },
    renderBoard() { ctx.renders += 1; },
    postBoard(body, note) { ctx.posts.push({ body, note }); },
  };
  vm.createContext(ctx);
  vm.runInContext(js.slice(from, to), ctx);
  return ctx;
}

test("both card actions are real buttons with their own accessible name", function () {
  const ctx = harness();
  const qa = ctx.cardQuickActions({ id: "c1", title: "Ship the gate", column: "todo" });
  assert.equal(qa.tagName, "SPAN");
  assert.equal(qa.className, "card-quick-actions");
  assert.equal(qa.childNodes.length, 2);
  for (const b of qa.childNodes) {
    assert.equal(b.tagName, "BUTTON");
    assert.equal(b.type, "button");
    // The plugin/page rule: every control carries an accessible name, and a
    // board full of cards needs the name to say *which* card.
    assert.ok(b.getAttribute("aria-label"), "action has an aria-label");
    assert.match(b.getAttribute("aria-label"), /Ship the gate/);
  }
});

test("Open card opens that card; Move to next column posts the move", function () {
  const ctx = harness();
  const qa = ctx.cardQuickActions({ id: "c1", title: "Ship the gate", column: "todo" });
  const stop = { preventDefault() {}, stopPropagation() {} };

  qa.childNodes[0].listeners.click(stop);
  assert.equal(ctx.openCardId, "c1");
  assert.equal(ctx.renders, 1);

  qa.childNodes[1].listeners.click(stop);
  // The vm's objects carry the vm's Object.prototype, so compare by value.
  assert.equal(
    JSON.stringify(ctx.posts),
    JSON.stringify([{ body: { op: "move", id: "c1", column: "doing" }, note: "Moved to Doing." }])
  );
});

test("the last column has nowhere to move to, and says so by doing nothing", function () {
  const ctx = harness();
  const qa = ctx.cardQuickActions({ id: "c2", title: "Done thing", column: "doing" });
  qa.childNodes[1].listeners.click({ preventDefault() {}, stopPropagation() {} });
  assert.equal(ctx.posts.length, 0);
});

test("the actions are a sibling of the card button, not a child of it", function () {
  // The card's <li> carries them, so the accessibility tree sees two ordinary
  // buttons instead of presentational children of a button.
  assert.match(js, /T\.li\(\{ class: "board-card-item" \}, cardNode\(c\), cardQuickActions\(c\)\)/);
  const cardNodeSrc = js.slice(js.indexOf("function cardNode(c) {"), js.indexOf("function cardQuickActions(c) {"));
  assert.ok(!/card-quick-actions/.test(cardNodeSrc), "cardNode must not build the actions overlay itself");
  assert.ok(!/card-quick-edit-btn/.test(js), "the occluded duplicate pencil is gone from board.js");
});

test("app.css positions the actions against the list item that holds them", function () {
  assert.match(css, /\.board-card-item \{ position: relative; \}/);
  assert.match(css, /\.board-card-item:hover \.card-quick-actions, \.board-card-item:focus-within \.card-quick-actions \{ display: flex; \}/);
  // A `.card ... .card-quick-actions` descendant rule would mean they had been
  // put back inside the button.
  assert.ok(!/\.card:hover \.card-quick-actions/.test(css));
  assert.ok(!/card-quick-edit-btn/.test(css), "the dead pencil's rules are gone too");
});
