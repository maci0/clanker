// Drives the shipped hidden-form and primary-button rules. A PF form class
// on a [hidden] node paints it; a bare button must not be an accent pill.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, "..", "app.css"), "utf8");
const html = readFileSync(join(here, "..", "index.html"), "utf8");
const uiSrc = readFileSync(join(here, "ui.js"), "utf8");

function ruleBody(selector) {
  const needle = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(needle + "\\s*\\{([^}]+)\\}");
  const m = css.match(re);
  assert.ok(m, "missing rule for " + selector);
  return m[1];
}

function loadUpgradePfForm() {
  const m = /export function upgradePfForm\(el\) \{([\s\S]*?)\n\}/.exec(uiSrc);
  assert.ok(m, "upgradePfForm missing from ui.js");
  return new Function("el", m[1]);
}

test("card-form stays in the tree as a hidden compatibility form", function () {
  assert.match(html, /id="card-form"[^>]*\bhidden\b|id="card-form" hidden/);
});

test("author CSS hides a hidden form so PF display cannot leak it", function () {
  const body = ruleBody("form[hidden]");
  assert.match(body, /display:\s*none/);
});

test("upgradePfForm does not stamp pf-v6-c-form onto a hidden form", function () {
  const upgradePfForm = loadUpgradePfForm();
  var added = null;
  upgradePfForm({
    tagName: "FORM",
    hidden: true,
    hasAttribute: function (n) { return n === "hidden"; },
    classList: {
      contains: function () { return false; },
      add: function (c) { added = c; },
    },
  });
  assert.equal(added, null);

  added = null;
  upgradePfForm({
    tagName: "FORM",
    hidden: false,
    hasAttribute: function () { return false; },
    classList: {
      contains: function () { return false; },
      add: function (c) { added = c; },
    },
  });
  assert.equal(added, "pf-v6-c-form");
});

test("rooms log is not a live region; status is", function () {
  assert.match(html, /id="chat-log"[^>]*role="log"/);
  assert.doesNotMatch(html, /id="chat-log"[^>]*aria-live=/);
  assert.match(html, /id="chat-status"[^>]*aria-live="polite"/);
  assert.match(html, /Loading channels/);
});

test("progress log is not a live region; status is", function () {
  assert.match(html, /id="progress-log"[^>]*role="log"/);
  assert.doesNotMatch(html, /id="progress-log"[^>]*aria-live=/);
  assert.match(html, /id="progress-status"[^>]*aria-live="polite"/);
});

test("header model chip is not a live region", function () {
  assert.match(html, /id="header-model"/);
  assert.doesNotMatch(html, /id="header-model"[^>]*aria-live=/);
});

test("run graph measures node heights after one layout flush", function () {
  const graphSrc = readFileSync(join(here, "..", "lib", "graph.js"), "utf8");
  assert.match(graphSrc, /void canvas\.offsetHeight/);
  const writeThenRead = graphSrc.indexOf("canvas.appendChild(d.el)") < graphSrc.indexOf("void canvas.offsetHeight");
  assert.ok(writeThenRead, "append all nodes before reading offsetHeight");
});

test("theme toggle opens a list, not a cycle", function () {
  const themeSrc = readFileSync(join(here, "theme.js"), "utf8");
  assert.match(themeSrc, /export function bindThemeToggle/);
  assert.match(html, /id="theme-toggle"[^>]*aria-haspopup="listbox"/);
  assert.doesNotMatch(themeSrc, /THEMES\.indexOf\(theme\) \+ 1/);
});

test("phone composer suggestions and attachment remove are 44px", function () {
  assert.match(css, /#view-chat \.suggestion \{ min-height: 44px/);
  assert.match(css, /\.attachment button \{[\s\S]*min-height: 44px/);
});

test("Search sits in Work, not the folded Set up group", function () {
  const work = html.slice(html.indexOf('id="rail-section-work"'), html.indexOf('id="rail-section-watch"'));
  const setup = html.slice(html.indexOf('id="rail-section-setup"'));
  assert.match(work, /id="tab-search"/);
  assert.doesNotMatch(setup, /id="tab-search"/);
});

test("conversation filter says it matches titles", function () {
  assert.match(html, /id="session-filter"[^>]*placeholder="Filter by title…"/);
});

test("channel name pattern explains the allowed characters", function () {
  assert.match(html, /id="chat-new-room-name"[^>]*title="Letters, numbers, underscores, and hyphens only/);
  assert.match(html, /id="chat-new-room-hint"/);
});

test("workspace plus minus hit 44px on coarse pointers", function () {
  assert.match(css, /@media \(pointer: coarse\) \{\s*\.rail-ws-btn \{ min-width: 44px; min-height: 44px; \}/);
});

test("required field labels are marked in CSS", function () {
  assert.match(css, /label:has\(\+ input\[required\]\)::after/);
});

test("parseCssColor reads rgb and hex", async function () {
  const { parseCssColor, cssColorMix, cssColorAlpha } = await import("./utils.js");
  assert.deepEqual(parseCssColor("rgb(11, 87, 208)"), [11, 87, 208]);
  assert.deepEqual(parseCssColor("#0b57d0"), [11, 87, 208]);
  assert.equal(cssColorAlpha("rgb(10, 20, 30)", 0.5), "rgba(10,20,30,0.5)");
  assert.equal(cssColorMix("rgb(0, 0, 0)", "rgb(100, 0, 0)", 0.5), "rgb(50,0,0)");
});

test("accent pill is primary/#submit only, not every unmarked button", function () {
  assert.doesNotMatch(
    css,
    /button:where\(:not\(\.pf-v6-c-button\)\)\s*\{[^}]*background:\s*var\(--accent\)/,
  );
  const primary = ruleBody("button.primary:where(:not(.pf-v6-c-button)),\n#submit:where(:not(.pf-v6-c-button))");
  assert.match(primary, /background:\s*var\(--accent\)/);
});
