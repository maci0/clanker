// Source contracts on the chat markdown path, plus a real render against a
// tiny DOM stub so a broken INLINE_RE fails here instead of in the browser.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, test } from "node:test";
import { installDom, serialize } from "./dom-stub.mjs";
import { renderMarkdown, renderMarkdownWithFences, appendCitedText } from "./markdown.js";

let restoreDom;

before(function () { restoreDom = installDom(); });

after(function () { restoreDom(); });

const here = dirname(fileURLToPath(import.meta.url));

const md = readFileSync(join(here, "markdown.js"), "utf8");

const app = readFileSync(join(here, "../app.js"), "utf8");

const css = readFileSync(join(here, "../tailwind.src.css"), "utf8");

// A ported file's shapes live in the Tailwind source, not the cabinet sheet.
const tw = readFileSync(join(here, "../tailwind.src.css"), "utf8");

test("INLINE_RE matches strike as well as bold", function () {
  assert.match(md, /~~\[\^~\\n\]\+~~/);
  assert.match(md, /tok\.slice\(0, 2\) === "~~"/);
});

test("live Chat streaming renders fences, not raw backticks", function () {
  assert.match(app, /var fragMd2 = renderMarkdownWithFences\(pend\)/);
  assert.doesNotMatch(app, /var fragMd2 = renderMarkdown\(pend\)/);
});

test("Rooms messages use the same fence-aware renderer", function () {
  assert.match(app, /function formatChatText\(raw\)/);
  assert.match(app, /renderMarkdownWithFences\(expandEmojiShortcodes\(raw\)\)/);
});

test("user chat bubbles render the prompt as markdown and keep the source", function () {
  assert.match(app, /you\._taskSource = task/);
  assert.match(app, /youBody\.appendChild\(renderMarkdownWithFences\(task\)\)/);
  // The bubble is utilities now, and its markdown body's shapes ride the
  // sheet's `[data-md="true"]` rule, which the element carries as an attribute.
  assert.match(app, /you\.setAttribute\("data-md", "true"\)/);
  assert.match(tw, /\[data-md="true"\] \.md-p/);
});

test("renderMarkdown turns bold, lists and fences into elements", function () {
  installDom();
  var bold = serialize(renderMarkdown("hello **world**"));
  assert.match(bold, /<strong>/);
  assert.match(bold, /world/);
  assert.doesNotMatch(bold, /\*\*world\*\*/);

  var list = serialize(renderMarkdown("- one\n- two"));
  assert.match(list, /<ul/);
  assert.match(list, /<li>/);
  assert.match(list, /one/);

  var fenced = serialize(renderMarkdownWithFences("see\n```js\nconst x = 1;\n```\n"));
  assert.match(fenced, /code-block/);
  assert.doesNotMatch(fenced, /```js/);
});


test("a citation chip carries the whole path, in whatever script the checkout is written in", function () {
  /* The citation's path is a filename on the operator's disk, so it is whatever
     their filesystem allowed to exist. The ASCII-only character class this
     replaces stopped at the first non-ASCII byte and the chip then opened the
     wrong file in the callgraph — "dokumentation/Uebersicht.zig:12" became
     "bersicht.zig:12" — while a path whose last segment was entirely
     non-ASCII produced no chip at all. macOS compounds it: the filesystem
     stores the capital U-umlaut decomposed (U+0055 U+0308), so a class without
     the combining marks dropped the accent even from an otherwise Latin path. */
  installDom();
  var cases = [
    ["see src/agent/loop.zig:42", "src/agent/loop.zig:42"],
    ["siehe dokumentation/\u00dcbersicht.zig:12", "dokumentation/\u00dcbersicht.zig:12"],
    ["dokumentation/U\u0308bersicht.zig:12", "dokumentation/U\u0308bersicht.zig:12"],
    ["patrz \u017ar\u00f3d\u0142a/main.rs:7", "\u017ar\u00f3d\u0142a/main.rs:7"],
    ["\u30c9\u30ad\u30b9\u30c8/main.ts:3", "\u30c9\u30ad\u30b9\u30c8/main.ts:3"],
    ["\u0441\u043c. \u0438\u0441\u0445\u043e\u0434\u043d\u0438\u043a\u0438/main.go:9", "\u0438\u0441\u0445\u043e\u0434\u043d\u0438\u043a\u0438/main.go:9"],
    ["docs/nai\u0308ve-r\u00e9sum\u00e9.md:1", "docs/nai\u0308ve-r\u00e9sum\u00e9.md:1"],
    // Column and range suffixes are still consumed, not left in the prose.
    ["\u89c1 src/main.zig:120:8", "src/main.zig:120:8"],
  ];

  for (var i = 0; i < cases.length; i++) {
    var parent = document.createElement("p");
    appendCitedText(parent, cases[i][0]);
    // The stub is childNodes-only, so the chip is found the way the renderer
    // built it rather than through a selector it does not implement.
    var chips = parent.childNodes.filter(function (c) { return c.getAttribute("data-ref") != null; });

    assert.equal(chips.length, 1, "expected one citation chip in " + JSON.stringify(cases[i][0]));
    assert.equal(chips[0].getAttribute("data-ref"), cases[i][1], "truncated citation in " + JSON.stringify(cases[i][0]));
  }
});
