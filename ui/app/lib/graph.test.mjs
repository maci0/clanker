// The per-step duration bar on a graph node. The scale it shares is the
// slowest step's `duration_ms`; dividing by the node object itself produced
// "[object Object]" and every bar got `width: NaN%`, a declaration the browser
// drops, so the bar never drew.
import assert from "node:assert/strict";
import { test } from "node:test";
import { buildNodeBox, buildStages, graphTotals, graphSummaryText, metricsFor, slowestWorthNaming, toDagInput } from "./graph.js";
import { fmtMs } from "../core/utils.js";

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
    setAttribute (n, v) { this.attrs[n] = v; },
    appendChild (child) { this.children.push(child); return child; },
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
    return buildNodeBox({ kind: node.kind, node }, opts && opts.slowest, 152, opts || {});
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

// A verdict (`check`) and an answered ask (`decision`) are steps of the
// iteration that produced them, exactly as the tool call beside them is. The
// agent loop writes both (`src/agent/loop.zig`) and the CLI renderer prints
// both (`tools/zig/graph.zig`); buildStages' `kind === "tool"` arm dropped
// them, so a failed gate had no node at all in the web run graph.
const verdict = { kind: "check", iteration: 1, label: "gate", detail: "3 tests failed", ok: false, duration_ms: 0 };
const answered = { kind: "decision", iteration: 1, label: "Which backend?", output: "sqlite", ok: true };
const readFile = { kind: "tool", iteration: 1, label: "read_file", detail: "", ok: true, duration_ms: 12 };
const answer = { kind: "final", iteration: 2, label: "final", detail: "stop", result_bytes: 40 };

const staged = buildStages([
  { kind: "llm", iteration: 1, label: "chat", prompt_tokens: 10, completion_tokens: 5, duration_ms: 100 },
  readFile,
  verdict,
  answered,
  answer,
]);

function stepLabels(stage) {
  return stage.tools.map(function (t) { return t.label; });
}

test("a verdict and an answered ask are steps of their iteration, not dropped", function () {
  assert.equal(staged.stages.length, 1);
  assert.deepEqual(stepLabels(staged.stages[0]), ["read_file", "gate", "Which backend?"]);
  assert.equal(staged.final, answer);
});

test("a step carries its own kind into the layout, so the filter and the box agree", function () {
  const data = toDagInput(staged);
  assert.deepEqual(data.map(function (d) { return d.kind; }), ["llm", "tool", "check", "decision", "final"]);
});

test("a check node reads as its verdict, the mark the CLI renderer prints", function () {
  assert.equal(metricsFor(verdict), "FAIL");
  assert.equal(metricsFor(Object.assign({}, verdict, { ok: true })), "pass");
});

test("a tool's byte count is a formatted unit, not a glued \"N B\"", function () {
  // `fmtInt(n) + " B"` printed "2048 B" where every German, French and Polish
  // reader expects "2 kB": the number was grouped by nothing at all. fmtBytes
  // is what the run list and the session rail already print for the same
  // number, so the graph now agrees with them at the runtime locale.
  for (const bytes of [0, 512, 2048, 1048576, 12582912]) {
    const unit = bytes >= 1048576 ? "megabyte" : bytes >= 1024 ? "kilobyte" : "byte";
    const value = bytes >= 1048576 ? bytes / 1048576 : bytes >= 1024 ? bytes / 1024 : bytes;
    const want = new Intl.NumberFormat(undefined, { style: "unit", unit, unitDisplay: "short", maximumFractionDigits: bytes >= 1048576 ? 1 : 0 }).format(value);
    assert.equal(metricsFor({ kind: "tool", label: "read_file", result_bytes: bytes, duration_ms: 5 }), want + " · " + fmtMs(5));
  }
});

test("the spoken summary does not call a verdict a tool call", function () {
  const said = graphSummaryText(staged);
  assert.ok(said.indexOf("check gate") !== -1, said);
  assert.ok(said.indexOf("question Which backend?") !== -1, said);
});