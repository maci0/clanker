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
  assert.match(js, /T\.li\(\{ class: "board-card-item" \}, cardNode\(c\), cardMemberControl\(c\), cardQuickActions\(c\)\)/);
  const cardNodeSrc = js.slice(js.indexOf("function cardNode(c) {"), js.indexOf("function memberInitials(name) {"));
  assert.ok(!/card-quick-actions/.test(cardNodeSrc), "cardNode must not build the actions overlay itself");
  assert.ok(!/card-quick-edit-btn/.test(js), "the occluded duplicate pencil is gone from board.js");
});

// ---------- the reassign control ----------
// A richer stub than the one above: these functions remove nodes, search their
// own subtree, and register a document-level dismiss listener.
function node(tag) {
  const e = {
    tagName: (tag || "").toUpperCase(),
    className: "",
    title: "",
    type: "",
    parentNode: null,
    childNodes: [],
    attrs: {},
    listeners: {},
    classList: { add(c) { e.className = (e.className ? e.className + " " : "") + c; } },
    appendChild(c) { c.parentNode = e; e.childNodes.push(c); return c; },
    remove() {
      if (!e.parentNode) return;
      const at = e.parentNode.childNodes.indexOf(e);
      if (at >= 0) e.parentNode.childNodes.splice(at, 1);
      e.parentNode = null;
    },
    setAttribute(k, v) { e.attrs[k] = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(e.attrs, k) ? e.attrs[k] : null; },
    addEventListener(t, f) { e.listeners[t] = f; },
    contains(n) { for (let p = n; p; p = p.parentNode) if (p === e) return true; return false; },
    querySelector(sel) {
      const want = sel.replace(".", "");
      for (const c of e.childNodes) {
        if ((c.className || "").split(" ").includes(want)) return c;
        const deep = c.querySelector && c.querySelector(sel);
        if (deep) return deep;
      }
      return null;
    },
    querySelectorAll() { return []; },
  };
  let text = "";
  Object.defineProperty(e, "textContent", {
    get() { return text || e.childNodes.map((c) => c.textContent || "").join(""); },
    set(v) { text = String(v == null ? "" : v); e.childNodes = []; },
  });
  return e;
}

// The real `memberPicker` and `dismissOnOutside` run too: a picker item's click
// bubbling into the avatar's own listener is the bug, so a stubbed picker would
// prove nothing.
function memberHarness() {
  const menus = js.slice(
    js.indexOf("function menuPopup(anchored) {"),
    js.indexOf("function cardNode(c) {")
  );
  const from = js.indexOf("function memberInitials(name) {");
  assert.ok(from >= 0, "memberInitials/cardMemberControl are top-level in board.js");
  const to = js.indexOf("/* The card's hover actions", from);
  assert.ok(to > from, "cardMemberControl still precedes the hover actions");

  const root = node("body");
  const ctx = {
    document: {
      createElement: node,
      createTextNode: (t) => { const n = node("#text"); n.textContent = t; return n; },
      querySelector: (sel) => root.querySelector(sel),
      addEventListener(t, f) { ctx.docListeners[t] = f; },
      removeEventListener(t) { delete ctx.docListeners[t]; },
    },
    docListeners: {},
    setTimeout: (f) => { ctx.timers.push(f); },
    timers: [],
    root,
    icon: (name) => { const i = node("svg"); i.attrs["data-icon"] = name; return i; },
    posts: [],
    postBoard(body, note) { ctx.posts.push({ body, note }); },
    _getKnownPeers: () => ["ada", "grace"],
  };
  vm.createContext(ctx);
  vm.runInContext(menus + "\n" + js.slice(from, to), ctx);
  ctx.mount = function (card) {
    const wrap = ctx.cardMemberControl(card);
    if (wrap) root.appendChild(wrap);
    return wrap;
  };
  return ctx;
}

test("the reassign control is a real button outside the card button", function () {
  const ctx = memberHarness();
  const wrap = ctx.mount({ id: "c1", title: "Ship the gate", assignee: "ada" });
  assert.equal(wrap.tagName, "SPAN");
  assert.equal(wrap.className, "card-members-overlay");
  const btn = wrap.childNodes[0];
  assert.equal(btn.tagName, "BUTTON");
  assert.equal(btn.type, "button");
  assert.equal(btn.textContent, "AD");
  assert.equal(btn.getAttribute("role"), null, "a <button> needs no role=button");
  assert.match(btn.getAttribute("aria-label"), /Reassign ada/);
  assert.match(btn.getAttribute("aria-label"), /Ship the gate/);
  assert.equal(btn.getAttribute("aria-haspopup"), "menu");
  assert.equal(btn.getAttribute("aria-expanded"), "false");
  // An em dash is a comment character here, not a UI one.
  assert.ok(!/—/.test(btn.title), "no em dash in a title a person reads");
  assert.equal(ctx.cardMemberControl({ id: "c2", title: "Nobody's" }), null);
});

test("the picker and its members are reachable, and the avatar in the card is not", function () {
  const ctx = memberHarness();
  const btn = ctx.mount({ id: "c1", title: "Ship the gate", assignee: "ada" }).childNodes[0];
  btn.listeners.click({ stopPropagation() {} });

  // The popup is a sibling of the button under the overlay span -- never a
  // descendant of it, and never of the card button, whose children ARIA treats
  // as presentational.
  const popup = ctx.root.querySelector(".member-picker-popup");
  assert.ok(popup, "the picker opened");
  assert.equal(popup.parentNode.className, "card-members-overlay");
  assert.ok(!btn.contains(popup), "the picker is not inside the button");
  assert.equal(btn.getAttribute("aria-expanded"), "true");
  // Remove member, then one item per known peer, all of them <button>.
  assert.equal(popup.childNodes.filter((n) => n.tagName === "BUTTON").length, 3);

  // And the avatar left in the card carries no role and no tab stop.
  const cardSrc = js.slice(js.indexOf("function cardNode(c) {"), js.indexOf("function memberInitials(name) {"));
  const slot = cardSrc.slice(cardSrc.indexOf("card-members"));
  assert.ok(!/role", "button"/.test(slot), "the in-card avatar must not be a control");
  assert.ok(!/tabIndex/.test(slot), "nor a tab stop");
  assert.match(slot, /aria-hidden", "true"/, "it is scenery, so it says so");
  assert.ok(!/memberPicker\(/.test(cardSrc), "cardNode must not append the picker into the card button");
});

test("picking a member closes the picker instead of reopening it", function () {
  const ctx = memberHarness();
  const btn = ctx.mount({ id: "c1", title: "Ship the gate", assignee: "ada" }).childNodes[0];
  btn.listeners.click({ stopPropagation() {} });
  const popup = ctx.root.querySelector(".member-picker-popup");

  // "grace": the Remove member row, then the two peers.
  const grace = popup.childNodes.filter((n) => n.tagName === "BUTTON")[2];
  assert.match(grace.textContent, /grace/);
  grace.listeners.click({});

  assert.equal(
    ctx.root.querySelector(".member-picker-popup"), null,
    "the pick used to bubble into the avatar's own click listener, which reopened it"
  );
  assert.equal(btn.getAttribute("aria-expanded"), "false", "aria-expanded must not latch on true");
  assert.equal(
    JSON.stringify(ctx.posts),
    JSON.stringify([{ body: { op: "update", id: "c1", assignee: "grace" }, note: "Assigned to grace." }])
  );
});

test("the button toggles its own picker and closes another card's", function () {
  const ctx = memberHarness();
  const a = ctx.mount({ id: "c1", title: "A", assignee: "ada" }).childNodes[0];
  const b = ctx.mount({ id: "c2", title: "B", assignee: "grace" }).childNodes[0];

  a.listeners.click({ stopPropagation() {} });
  a.listeners.click({ stopPropagation() {} });
  assert.equal(ctx.root.querySelector(".member-picker-popup"), null, "a second click closes it");
  assert.equal(a.getAttribute("aria-expanded"), "false");

  a.listeners.click({ stopPropagation() {} });
  b.listeners.click({ stopPropagation() {} });
  assert.equal(a.getAttribute("aria-expanded"), "false", "opening B must not leave A claiming to be open");
  assert.equal(b.getAttribute("aria-expanded"), "true");
});

test("app.css paints the reassign button where the card's own avatar sits", function () {
  // The card is `overflow: hidden` and is the popup's containing block, so a
  // picker opened from inside it was clipped to the card. The overlay is
  // positioned against the list item, which clips nothing.
  assert.match(css, /\.card-member-slot \{ visibility: hidden; \}/);
  assert.match(css, /\.card-members-overlay \{[^}]*position: absolute/);
  assert.match(css, /\.card-members-overlay \{[^}]*bottom: calc\(0\.5rem \+ 1px\)/);
  assert.match(css, /\.card-body \{ padding: 0\.55rem 0\.65rem 0\.5rem;/, "that offset is the card body's own padding");
  assert.match(css, /\.card \{[^}]*overflow: hidden/);
});

test("app.css positions the actions against the list item that holds them", function () {
  assert.match(css, /\.board-card-item \{ position: relative; \}/);
  assert.match(css, /\.board-card-item:hover \.card-quick-actions, \.board-card-item:focus-within \.card-quick-actions \{ display: flex; \}/);
  // A `.card ... .card-quick-actions` descendant rule would mean they had been
  // put back inside the button.
  assert.ok(!/\.card:hover \.card-quick-actions/.test(css));
  assert.ok(!/card-quick-edit-btn/.test(css), "the dead pencil's rules are gone too");
});
