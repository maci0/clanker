// Drives the shipped Chat scroll helpers and the shipped Chat shell markup.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  conversationScroller,
  nearBottom,
  scrollChatToLatest,
  syncScrollButton,
} from "./scroll.js";

const here = dirname(fileURLToPath(import.meta.url));

function makeBox(opts) {
  var height = opts && opts.height != null ? opts.height : 1000;
  var view = opts && opts.view != null ? opts.view : 200;
  var top = opts && opts.top != null ? opts.top : 0;
  return {
    scrollHeight: height,
    clientHeight: view,
    scrollTop: top,
    scrollTo: function (arg) {
      if (typeof arg === "number") this.scrollTop = arg;
      else if (arg && typeof arg.top === "number") this.scrollTop = arg.top;
    },
  };
}

test("nearBottom is false at the top of a tall conversation box", function () {
  var box = makeBox({ top: 0 });
  assert.equal(nearBottom(box), false);
});

test("nearBottom is true when the conversation box is within the floor of the end", function () {
  var box = makeBox({ top: 880 });
  assert.equal(nearBottom(box), true);
});

test("scrollChatToLatest moves the conversation box, not window.scrollY", function () {
  var box = makeBox({ top: 0 });
  var windowY = 0;
  var prevDoc = globalThis.document;
  var prevWin = globalThis.window;
  globalThis.document = {
    querySelector: function (sel) {
      return sel === "#view-chat .conversation-scroll" ? box : null;
    },
  };
  globalThis.window = {
    scrollY: 0,
    scrollTo: function (arg) {
      windowY = arg && arg.top != null ? arg.top : arg;
    },
  };
  try {
    assert.equal(conversationScroller(), box);
    scrollChatToLatest("auto");
    assert.equal(box.scrollTop, box.scrollHeight);
    assert.equal(windowY, 0);
  } finally {
    globalThis.document = prevDoc;
    globalThis.window = prevWin;
  }
});

test("Jump-to-latest button stays hidden while the conversation is at the end", function () {
  var box = makeBox({ top: 900 });
  var transcript = {
    querySelector: function (sel) {
      return sel === ".turn" ? {} : null;
    },
  };
  var btn = { hidden: false };
  syncScrollButton(transcript, btn, box);
  assert.equal(btn.hidden, true);
});

test("shipped Chat markup is a session-first PF column", function () {
  var html = readFileSync(join(here, "..", "index.html"), "utf8");
  var css = readFileSync(join(here, "..", "app.css"), "utf8");
  assert.match(html, /class="pf-v6-c-page"/);
  assert.match(html, /class="pf-v6-c-masthead"/);
  assert.match(html, /pf-v6-c-page__sidebar/);
  assert.match(html, /id="rail-context"/);
  assert.doesNotMatch(html, /id="rail-context"[^>]*\bhidden\b/);
  assert.match(html, /class="conversation-header"/);
  assert.match(html, /class="conversation-scroll"/);
  assert.match(html, /id="task-form" class="composer"/);
  assert.match(css, /--accent:\s*#1d5c9e/);
  assert.match(css, /#view-chat \.conversation-scroll/);
  assert.match(css, /#view-chat \.composer/);
});
