// Empty Chat and Board first-paint contracts from the critique pass.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, "..", "index.html"), "utf8");
const css = readFileSync(join(here, "..", "app.css"), "utf8");

test("empty Chat hides session verbs and find", function () {
  assert.match(css, /#view-chat\.chat-empty #session-acts-body/);
  assert.match(css, /#view-chat\.chat-empty #transcript-tools/);
  assert.match(css, /display:\s*none/);
});

test("run-shape disclosure holds the four mode toggles", function () {
  assert.match(html, /id="run-shape"/);
  assert.match(html, /Long run \(1000 steps\)/);
  assert.match(html, /Isolated worktree/);
  assert.doesNotMatch(html, />No limit</);
  const shape = html.slice(html.indexOf('id="run-shape"'), html.indexOf("voice-btn"));
  assert.match(shape, /id="plan-mode"/);
  assert.match(shape, /id="research-mode"/);
  assert.match(shape, /id="unlimited-iterations"/);
  assert.match(shape, /id="worktree-mode"/);
});

test("submit is a labeled Run control", function () {
  assert.match(html, /id="submit"[^>]*>Run</);
});

test("cancel is a labeled Stop pill, not an icon-only circle", function () {
  const app = readFileSync(join(here, "..", "app.js"), "utf8");
  assert.match(app, /createTextNode\("Stop"\)/);
  assert.doesNotMatch(css, /\.composer \.toolbar #cancel \{[^}]*aspect-ratio:\s*1/);
});

test("sidebar title filter matches words the compact label drops", async function () {
  const { sessionMatchesFilter, summarizeTitle } = await import("./utils.js");
  const title = "Investigate the schedule run-due empty ledger";
  assert.ok(!/ledger/i.test(summarizeTitle(title)));
  assert.equal(sessionMatchesFilter({ title: title, id: "sess-1", messages: 2 }, "ledger"), true);
  assert.equal(sessionMatchesFilter({ title: title, id: "sess-1", messages: 2 }, "xyzzy"), false);
  assert.equal(sessionMatchesFilter({ title: title, id: "sess-1", messages: 2 }, ""), true);
  assert.equal(sessionMatchesFilter({ title: "other", id: "sess-ledger", messages: 1 }, "ledger"), true);
});

test("Board filters sit behind a disclosure and Only mine is singular", function () {
  assert.match(html, /class="board-filter-fold"/);
  assert.match(html, /Saves a Backlog card/);
  const mines = html.match(/id="board-mine"/g) || [];
  assert.equal(mines.length, 1);
  assert.doesNotMatch(html, /id="board-filter-mine"/);
});
