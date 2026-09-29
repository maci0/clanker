// Drives the shipped overlay focus helpers over a stub DOM: which nodes the
// trap counts as tab stops, and where Tab lands at each end of a dialog.
import assert from "node:assert/strict";
import test from "node:test";
import { focusableIn, trapOverlayTab } from "./overlay.js";

// The shipped helper takes a node and calls `querySelectorAll`, `contains`,
// `getClientRects` and `focus`, so a stub has to answer all four for the trap
// to run at all. Anything the real element does not do here fails the test
// rather than passing on a stub that agrees with itself.
function stubNode(specs, opts) {
  const nodes = specs.map(function (s, i) {
    return Object.assign({
      id: s.id || "n" + i,
      tag: s.tag || "button",
      hidden: false,
      getClientRects: function () { return [{}]; },
      focus: function () { this.focused = true; },
      focused: false,
    }, {});
  });
  const node = {
    querySelectorAll: function () { return nodes.slice(); },
    contains: function (n) { return nodes.indexOf(n) >= 0; },
  };
  // The shipped trap reads `document.activeElement`, so the page has to exist
  // to run it: `focus()` here only marks the node, and the document stub says
  // where focus already was.
  globalThis.document = { activeElement: opts && opts.activeIndex != null ? nodes[opts.activeIndex] : (opts ? opts.active : null) };
  return { node, nodes, active: function () { return globalThis.document.activeElement; } };
}

test("a disclosure summary inside a dialog is a tab stop the trap knows about", function () {
  // The browser puts `summary` in the tab order on its own, so the trap has to
  // count it: without it, Tab from the control before a fold walked off the end
  // of the dialog into the page under the scrim.
  const { node, nodes } = stubNode([
    { id: "close", tag: "button" },
    { id: "fold", tag: "summary" },
    { id: "field", tag: "input" },
  ], { active: null });
  const items = focusableIn(node);
  assert.deepEqual(items.map(function (n) { return n.id; }), ["close", "fold", "field"]);
  assert.equal(items.length, 3);
  assert.equal(nodes[1].tag, "summary");
});

test("Tab at the last tab stop wraps to the first, not out of the dialog", function () {
  const { node, nodes } = stubNode([
    { id: "close", tag: "button" },
    { id: "fold", tag: "summary" },
    { id: "field", tag: "input" },
  ], { active: undefined });
  let prevented = false;
  trapOverlayTab({ shiftKey: false, preventDefault: function () { prevented = true; } }, node);
  assert.equal(prevented, true);
  assert.equal(nodes[0].focused, true, "focus wrapped to the first tab stop");
  assert.equal(nodes[2].focused, false);
});

test("Shift+Tab at the first tab stop wraps to the last", function () {
  const { node, nodes } = stubNode([
    { id: "close", tag: "button" },
    { id: "fold", tag: "summary" },
  ], { activeIndex: 0 });
  trapOverlayTab({ shiftKey: true, preventDefault: function () {} }, node);
  assert.equal(nodes[1].focused, true, "focus wrapped to the summary at the end");
  assert.equal(nodes[0].focused, false);
});

test("a dialog whose only tab stop is a summary still traps Tab", function () {
  const { node, nodes } = stubNode([{ id: "fold", tag: "summary" }], { active: null });
  trapOverlayTab({ shiftKey: false, preventDefault: function () {} }, node);
  assert.equal(nodes[0].focused, true);
});
