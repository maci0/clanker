import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { applyDoneStats, applyLiveUsage, beginLiveTurn, emptyRunMetrics, estTokens, formatRunMetrics, formatRunMetricsParts, fmtTok, liveElapsedMs, noteFirstToken, noteLiveChars } from "./run-metrics.js";

const here = dirname(fileURLToPath(import.meta.url));
const app = readFileSync(join(here, "..", "app.js"), "utf8");

test("fmtTok uses compact M/K units", function () {
  assert.equal(fmtTok(225000000), "225.0M");
  assert.equal(fmtTok(972000), "972.0K");
  assert.equal(fmtTok(40), "40");
});

test("formatRunMetrics is empty before any run", function () {
  assert.equal(formatRunMetrics(emptyRunMetrics()), "");
});

test("live tick grows LLM time without waiting for done", function () {
  var m = emptyRunMetrics();
  m.live = true;
  m.liveStartedAt = 1000;
  m.turnCount = 1;
  var t0 = formatRunMetrics(m, 1000);
  var t1 = formatRunMetrics(m, 4000);
  assert.match(t0, /1 turn/);
  assert.match(t0, /1 step/);
  assert.match(t1, /3/);
  assert.notEqual(t0, t1);
  assert.equal(liveElapsedMs(m, 4000), 3000);
});

test("tool time is carved out of live elapsed", function () {
  var m = emptyRunMetrics();
  m.live = true;
  m.liveStartedAt = 0;
  m.liveToolMs = 2000;
  m.turnCount = 1;
  var line = formatRunMetrics(m, 5000);
  assert.match(line, /Tool call/);
  assert.match(line, /2/);
});

test("done event folds this turn into session totals and stops live", function () {
  var m = emptyRunMetrics();
  m.live = true;
  m.liveStartedAt = 0;
  m.liveSteps = 2;
  m.liveToolMs = 500;
  m.liveTtftMs = 300;
  m.now = 2000;
  applyDoneStats(m, {
    ms: 2000,
    prompt_tokens: 1000,
    completion_tokens: 40,
    cache_hit_tokens: 800,
    cache_miss_tokens: 200,
    ttft_ms_total: 280,
    ttft_samples: 1,
  });
  assert.equal(m.live, false);
  assert.equal(m.completedSteps, 3);
  assert.equal(m.completedToolMs, 500);
  assert.equal(m.completedLlmMs, 1500);
  assert.equal(m.prompt_tokens, 1000);
  assert.equal(m.completion_tokens, 40);
  m.turnCount = 1;
  var line = formatRunMetrics(m, 2000);
  assert.match(line, /1 turn/);
  assert.match(line, /3 step/);
  assert.match(line, /Cache hit 80%/);
  assert.match(line, /Input 1\.0K tok/);
  assert.match(line, /Output 40 tok/);
  assert.match(line, /TTFT avg/);
});

test("beginLiveTurn counts the turn immediately so the strip is not 0 turns", function () {
  var m = beginLiveTurn(emptyRunMetrics(), 1000);
  assert.equal(m.live, true);
  assert.equal(m.turnCount, 1);
  assert.match(formatRunMetrics(m, 1000), /1 turn/);
});

test("live TTFT shows before tokens arrive", function () {
  var m = beginLiveTurn(emptyRunMetrics(), 0);
  noteFirstToken(m, 320);
  var line = formatRunMetrics(m, 1000);
  assert.match(line, /TTFT/);
  assert.doesNotMatch(line, /Input/);
});

test("app.js ticks the strip from rAF and stream usage events", function () {
  assert.match(app, /from "\.\/core\/run-metrics\.js"/);
  assert.match(app, /beginLiveTurn\(/);
  assert.match(app, /applyDoneStats\(/);
  assert.match(app, /applyLiveUsage\(/);
  assert.match(app, /noteFirstToken\(/);
  assert.match(app, /requestAnimationFrame\(tick\)/);
  assert.match(app, /function startElapsed[\s\S]*paintRunMetrics\(/);
  assert.match(app, /function switchSession[\s\S]*resetSessionMetrics\(/);
  assert.match(app, /evt\.type === "usage"/);
  assert.doesNotMatch(app, /function renderRunMetrics\(/);
  assert.doesNotMatch(app, /function fmtTok\(/);
});

test("usage events and streamed chars show tokens before done", function () {
  var m = beginLiveTurn(emptyRunMetrics(), 0);
  applyLiveUsage(m, { prompt_tokens: 1200, completion_tokens: 40, cache_hit_tokens: 900, cache_miss_tokens: 100 });
  noteLiveChars(m, 80);
  var line = formatRunMetrics(m, 2000);
  assert.match(line, /Input 1\.2K tok/);
  assert.match(line, /Output 60 tok/);
  assert.match(line, /Cache hit 90%/);
  assert.match(line, /tok\/s/);
  var parts = formatRunMetricsParts(m, 2000);
  assert.ok(parts.some(function (p) { return p.key === "io"; }));
});

test("estTokens is 4 chars per token", function () {
  assert.equal(estTokens(0), 0);
  assert.equal(estTokens(4), 1);
  assert.equal(estTokens(5), 2);
});

test("second turn accumulates tokens and steps", function () {
  var m = emptyRunMetrics();
  m.completedSteps = 3;
  m.completedToolMs = 500;
  m.completedLlmMs = 1500;
  m.prompt_tokens = 1000;
  m.completion_tokens = 40;
  m.live = true;
  m.liveStartedAt = 10000;
  m.liveSteps = 1;
  applyDoneStats(m, { ms: 1000, prompt_tokens: 200, completion_tokens: 10 });
  assert.equal(m.completedSteps, 5);
  assert.equal(m.prompt_tokens, 1200);
  assert.equal(m.completion_tokens, 50);
});
