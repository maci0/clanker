// The per-step duration bar on a graph node. The scale it shares is the
// slowest step's `duration_ms`; dividing by the node object itself produced
// "[object Object]" and every bar got `width: NaN%`, a declaration the browser
// drops, so the bar never drew.
import assert from "node:assert/strict";
import { test } from "node:test";
import { buildNodeBox, graphTotals, slowestWorthNaming } from "./graph.js";

// The smallest element the builder needs: children, a className, textContent,
// dataset, and a style object the assertions read back.
function fakeElement(tag) {
  return {
    tagName: String(tag).toUpperCase(),
    children: [],
    className: "",
    textContent: "",
    dataset: {},
    style: {},
    title: "",
    attrs: {},
    setAttribute: function (n, v) { this.attrs[n] = v; },
    appendChild: function (child) { this.children.push(child); return child; },
  };
}

// buildNodeBox reads the ambient document, as the browser supplies it. The
// fake is installed per call rather than at module scope, and the incoming
// variant was no wider: the suites share one process, so a document left
// behind here outlived this file and any later suite that needs a fuller stub
// (the markdown renderer's fragment) found `createDocumentFragment` missing.
function build(node, opts) {
  const saved = globalThis.document;
  globalThis.document = { createElement: fakeElement };
  try {
    return buildNodeBox({ kind: node.kind, node: node }, opts && opts.slowest, 152, opts || {});
  } finally {
    globalThis.document = saved;
  }
}

function barFill(box) {
  const bar = box.children.find(function (c) { return c.className.indexOf("bg-rule") >= 0; });
  return bar && bar.children[0];
}

const slow = { kind: "tool", label: "read_file", detail: "", duration_ms: 4000 };
const quick = { kind: "tool", label: "grep", detail: "", duration_ms: 100 };

test("a step's bar is its share of the slowest step, in percent", function () {
  assert.equal(barFill(build(quick, { slowest: slow })).style.width, "3%");
  assert.equal(barFill(build(slow, { slowest: slow })).style.width, "100%");
});

test("an untimed run has no scale, so the bar keeps its minimum width", function () {
  const box = build(quick, {});
  assert.equal(barFill(box).style.width, "2%");
});

test("a zero-duration step beside a real one is the minimum, not zero", function () {
  const untimed = { kind: "tool", label: "no timing", detail: "", duration_ms: 0 };
  assert.equal(barFill(build(untimed, { slowest: slow })).style.width, "2%");
});

test("the slowest step is only named when one step dominates", function () {
  const built = {
    stages: [{ iteration: 0, llm: { kind: "llm", duration_ms: 100, prompt_tokens: 1, completion_tokens: 1 }, tools: [slow] }],
    final: null,
  };
  const totals = graphTotals(built);
  assert.equal(slowestWorthNaming(totals), slow);

  // Four equal steps: the largest is a quarter of the work, under the 40%
  // that makes one step worth naming.
  const even = {
    stages: [{
      iteration: 0,
      llm: { kind: "llm", duration_ms: 1000, prompt_tokens: 1, completion_tokens: 1 },
      tools: [
        { kind: "tool", label: "a", detail: "", duration_ms: 1000 },
        { kind: "tool", label: "b", detail: "", duration_ms: 1000 },
        { kind: "tool", label: "c", detail: "", duration_ms: 1000 },
      ],
    }],
    final: null,
  };
  assert.equal(slowestWorthNaming(graphTotals(even)), null);
});
