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

test("a page load starts a new conversation instead of replaying the last session", function () {
  const app = readFileSync(join(here, "..", "app.js"), "utf8");
  assert.match(app, /function loadSession\(\)/);
  assert.match(app, /A visit starts a new conversation/);
  assert.doesNotMatch(app, /getItem\("clanker\.session"\)/);
  assert.doesNotMatch(app, /The conversation you were last in is replayed/);
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

test("the Advanced fold holds a per-chat reasoning-effort pin", function () {
  const params = html.slice(html.indexOf('id="params"'), html.indexOf('id="run-shape"'));
  assert.match(params, /id="param-effort"/);
  for (const v of ["none", "low", "medium", "high", "max"]) {
    assert.match(params, new RegExp('<option value="' + v + '"'));
  }
  const app = readFileSync(join(here, "..", "app.js"), "utf8");
  assert.match(app, /reasoning_effort: opts\.reasoning_effort \|\| ""/);
  // A pinned effort must stay visible while the fold is closed.
  assert.match(app, /function syncAdvancedSummary\(\)/);
  const picker = readFileSync(join(here, "modelpicker.js"), "utf8");
  assert.match(picker, /out\.reasoning_effort = re/);
  assert.match(picker, /clanker\.effort/);
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

test("summarizeTitle never splits a surrogate pair on the length cut", async function () {
  const { summarizeTitle } = await import("./utils.js");
  // A title of astral emoji: every unit is one codepoint, so a codepoint cut
  // yields whole emoji, while a UTF-16 .slice(0, 28) would end mid-pair.
  const title = "\u{1F680}".repeat(30);
  const out = summarizeTitle(title);
  assert.ok(Array.from(out).length >= 1 && Array.from(out).length <= 28);
  for (const ch of out) {
    const cp = ch.codePointAt(0);
    const lone = ch.length === 1 && cp >= 0xd800 && cp <= 0xdfff;
    assert.ok(!lone, "lone surrogate in output: " + JSON.stringify(ch));
  }
});

test("summarizeTitle keeps accented and non-Latin letters on word edges", async function () {
  const { summarizeTitle } = await import("./utils.js");
  // The old ASCII trim class [A-Za-z0-9'] ate accents off word edges and
  // stripped a CJK title to nothing; a letter is a letter in any script.
  assert.equal(summarizeTitle("Água do poço"), "Água poço");
  assert.equal(summarizeTitle('"Émigré" notes'), "Émigré notes");
  assert.ok(/测试/.test(summarizeTitle("测试标题 one")));
});

test("Board filters sit behind a disclosure and Only mine is singular", function () {
  assert.match(html, /class="board-filter-fold"/);
  assert.match(html, /Saves a Ready card/);
  const mines = html.match(/id="board-mine"/g) || [];
  assert.equal(mines.length, 1);
  assert.doesNotMatch(html, /id="board-filter-mine"/);
});
