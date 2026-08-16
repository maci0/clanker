// Source contracts on the chat markdown path, plus a real render against a
// tiny DOM stub so a broken INLINE_RE fails here instead of in the browser.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { serialize } from "./dom-stub.mjs";
import { renderMarkdown, renderMarkdownWithFences } from "./markdown.js";

const here = dirname(fileURLToPath(import.meta.url));
const md = readFileSync(join(here, "markdown.js"), "utf8");
const app = readFileSync(join(here, "../app.js"), "utf8");
const css = readFileSync(join(here, "../app.css"), "utf8");

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
  assert.match(css, /\.turn-you\.md \.md-p/);
});

test("renderMarkdown turns bold, lists and fences into elements", function () {
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
