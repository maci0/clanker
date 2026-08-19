// Session-lifetime composer strip: turns, steps, LLM vs tool time, TTFT,
// tok/s, cache, input/output. Pure so the tick path and tests share one
// formatter. Times tick every frame. Tokens come from mid-run `usage`
// events (this turn's totals) plus a live output estimate from streamed
// chars until the next official snapshot.
import { fmtInt, fmtMs } from "./utils.js";

export function fmtTok(n) {
  if (typeof n !== "number" || !isFinite(n)) return "0";
  var abs = Math.abs(n);
  if (abs >= 1e6) return (n / 1e6).toFixed(1) + "M";
  if (abs >= 1e3) return (n / 1e3).toFixed(1) + "K";
  return String(Math.round(n));
}

export function estTokens(chars) {
  if (typeof chars !== "number" || chars <= 0) return 0;
  return Math.ceil(chars / 4);
}

export function emptyRunMetrics() {
  return {
    completedSteps: 0,
    completedToolMs: 0,
    completedLlmMs: 0,
    prompt_tokens: 0,
    completion_tokens: 0,
    cache_hit_tokens: 0,
    cache_miss_tokens: 0,
    ttft_ms_total: 0,
    ttft_samples: 0,
    live: false,
    liveStartedAt: 0,
    liveToolMs: 0,
    liveSteps: 0,
    liveTtftMs: null,
    livePrompt: 0,
    liveCompletion: 0,
    liveCacheHit: 0,
    liveCacheMiss: 0,
    liveEstChars: 0,
    liveTtftTotal: 0,
    liveTtftSamples: 0,
    turnCount: 0,
    now: 0,
  };
}

// The live counters carry one turn only, so both ends of a turn clear them.
function clearLiveTurn(m) {
  m.liveToolMs = 0;
  m.liveSteps = 0;
  m.liveTtftMs = null;
  m.livePrompt = 0;
  m.liveCompletion = 0;
  m.liveCacheHit = 0;
  m.liveCacheMiss = 0;
  m.liveEstChars = 0;
  m.liveTtftTotal = 0;
  m.liveTtftSamples = 0;
}

export function beginLiveTurn(m, now) {
  m.live = true;
  m.liveStartedAt = typeof now === "number" ? now : 0;
  clearLiveTurn(m);
  m.turnCount += 1;
  return m;
}

export function liveElapsedMs(m, now) {
  if (!m.live) return 0;
  return Math.max((now || m.now || 0) - m.liveStartedAt, 0);
}

export function noteFirstToken(m, now) {
  if (!m.live || m.liveTtftMs != null) return m;
  m.liveTtftMs = Math.max((now || 0) - m.liveStartedAt, 0);
  return m;
}

export function noteLiveChars(m, n) {
  if (!m || !m.live || typeof n !== "number" || n <= 0) return m;
  m.liveEstChars += n;
  return m;
}

export function applyLiveUsage(m, evt) {
  if (!m || !evt) return m;
  if (typeof evt.prompt_tokens === "number") m.livePrompt = evt.prompt_tokens;
  if (typeof evt.completion_tokens === "number") m.liveCompletion = evt.completion_tokens;
  if (typeof evt.cache_hit_tokens === "number") m.liveCacheHit = evt.cache_hit_tokens;
  if (typeof evt.cache_miss_tokens === "number") m.liveCacheMiss = evt.cache_miss_tokens;
  if (typeof evt.ttft_samples === "number" && evt.ttft_samples > 0) {
    m.liveTtftTotal = evt.ttft_ms_total || 0;
    m.liveTtftSamples = evt.ttft_samples;
  }
  m.liveEstChars = 0;
  return m;
}

function promptTokens(m) {
  return (m.prompt_tokens || 0) + (m.livePrompt || 0);
}

function completionTokens(m) {
  return (m.completion_tokens || 0) + (m.liveCompletion || 0) + estTokens(m.liveEstChars || 0);
}

function cacheHit(m) {
  return (m.cache_hit_tokens || 0) + (m.liveCacheHit || 0);
}

function cacheMiss(m) {
  return (m.cache_miss_tokens || 0) + (m.liveCacheMiss || 0);
}

export function formatRunMetricsParts(m, now) {
  if (!m) return [];
  var clock = typeof now === "number" ? now : m.now;
  var liveMs = liveElapsedMs(m, clock);
  var toolMs = m.completedToolMs + m.liveToolMs;
  var llmMs = m.completedLlmMs + (m.live ? Math.max(liveMs - m.liveToolMs, 0) : 0);
  var steps = m.completedSteps + m.liveSteps + (m.live ? 1 : 0);
  var turns = m.turnCount || 0;
  if (!m.live && turns === 0 && steps === 0 && toolMs === 0 && llmMs === 0) return [];

  var parts = [];
  parts.push({
    key: "turns",
    text: fmtInt(turns) + " turn" + (turns === 1 ? "" : "s") + " · " + fmtInt(steps) + " step" + (steps === 1 ? "" : "s"),
  });
  parts.push({
    key: "time",
    text: "LLM " + fmtMs(llmMs) + " · Tool call " + fmtMs(toolMs),
  });
  var bits2 = [];
  var ttftSamples = (m.ttft_samples || 0) + (m.liveTtftSamples || 0);
  var ttftTotal = (m.ttft_ms_total || 0) + (m.liveTtftTotal || 0);
  if (ttftSamples > 0) bits2.push("TTFT avg " + fmtMs(ttftTotal / ttftSamples));
  else if (typeof m.liveTtftMs === "number") bits2.push("TTFT " + fmtMs(m.liveTtftMs));
  var completion = completionTokens(m);
  var totalMs = llmMs + toolMs;
  if (completion > 0 && llmMs > 0) bits2.push((completion / (llmMs / 1000)).toFixed(0) + " tok/s");
  else if (completion > 0 && totalMs > 0) bits2.push((completion / (totalMs / 1000)).toFixed(0) + " tok/s");
  if (bits2.length) parts.push({ key: "rate", text: bits2.join(" · ") });
  var hit = cacheHit(m);
  var miss = cacheMiss(m);
  if (hit + miss > 0) parts.push({ key: "cache", text: "Cache hit " + ((hit / (hit + miss)) * 100).toFixed(0) + "%" });
  var prompt = promptTokens(m);
  if (prompt || completion) {
    parts.push({ key: "io", text: "Input " + fmtTok(prompt) + " tok · Output " + fmtTok(completion) + " tok" });
  }
  return parts;
}

export function formatRunMetrics(m, now) {
  return formatRunMetricsParts(m, now).map(function (p) { return p.text; }).join(" | ");
}

export function applyDoneStats(m, evt) {
  var tool = m.liveToolMs;
  var wall = typeof evt.ms === "number" ? evt.ms : liveElapsedMs(m, m.now);
  m.completedSteps += m.liveSteps + 1;
  m.completedToolMs += tool;
  m.completedLlmMs += Math.max(wall - tool, 0);
  if (typeof evt.prompt_tokens === "number") m.prompt_tokens += evt.prompt_tokens;
  else m.prompt_tokens += m.livePrompt || 0;
  if (typeof evt.completion_tokens === "number") m.completion_tokens += evt.completion_tokens;
  else m.completion_tokens += m.liveCompletion || 0;
  if (typeof evt.cache_hit_tokens === "number") m.cache_hit_tokens += evt.cache_hit_tokens;
  else m.cache_hit_tokens += m.liveCacheHit || 0;
  if (typeof evt.cache_miss_tokens === "number") m.cache_miss_tokens += evt.cache_miss_tokens;
  else m.cache_miss_tokens += m.liveCacheMiss || 0;
  if (typeof evt.ttft_samples === "number" && evt.ttft_samples > 0) {
    m.ttft_ms_total += evt.ttft_ms_total || 0;
    m.ttft_samples += evt.ttft_samples;
  } else if (typeof m.liveTtftMs === "number") {
    m.ttft_ms_total += m.liveTtftMs;
    m.ttft_samples += 1;
  }
  m.live = false;
  m.liveStartedAt = 0;
  clearLiveTurn(m);
  return m;
}
