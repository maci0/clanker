// Session-lifetime composer strip: turns, steps, LLM vs tool time, TTFT,
// tok/s, cache, input/output. Pure so the tick path and tests share one
// formatter. Token totals only exist after a `done` event; times and steps
// update while the turn is still running.
import { fmtInt, fmtMs } from "./utils.js";

export function fmtTok(n) {
  if (typeof n !== "number" || !isFinite(n)) return "0";
  var abs = Math.abs(n);
  if (abs >= 1e6) return (n / 1e6).toFixed(1) + "M";
  if (abs >= 1e3) return (n / 1e3).toFixed(1) + "K";
  return String(Math.round(n));
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
    turnCount: 0,
    now: 0,
  };
}

export function beginLiveTurn(m, now) {
  m.live = true;
  m.liveStartedAt = typeof now === "number" ? now : 0;
  m.liveToolMs = 0;
  m.liveSteps = 0;
  m.liveTtftMs = null;
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

export function formatRunMetrics(m, now) {
  if (!m) return "";
  var clock = typeof now === "number" ? now : m.now;
  var liveMs = liveElapsedMs(m, clock);
  var toolMs = m.completedToolMs + m.liveToolMs;
  var llmMs = m.completedLlmMs + (m.live ? Math.max(liveMs - m.liveToolMs, 0) : 0);
  var steps = m.completedSteps + m.liveSteps + (m.live ? 1 : 0);
  var turns = m.turnCount || 0;
  if (!m.live && turns === 0 && steps === 0 && toolMs === 0 && llmMs === 0) return "";

  var parts = [];
  parts.push(fmtInt(turns) + " turn" + (turns === 1 ? "" : "s") + " · " + fmtInt(steps) + " step" + (steps === 1 ? "" : "s"));
  parts.push("LLM " + fmtMs(llmMs) + " · Tool call " + fmtMs(toolMs));
  var bits2 = [];
  if (m.ttft_samples > 0) {
    bits2.push("TTFT avg " + fmtMs(m.ttft_ms_total / m.ttft_samples));
  } else if (typeof m.liveTtftMs === "number") {
    bits2.push("TTFT " + fmtMs(m.liveTtftMs));
  }
  var completion = m.completion_tokens || 0;
  var totalMs = llmMs + toolMs;
  if (completion > 0 && totalMs > 0) bits2.push((completion / (totalMs / 1000)).toFixed(0) + " tok/s");
  if (bits2.length) parts.push(bits2.join(" · "));
  var hit = m.cache_hit_tokens || 0;
  var miss = m.cache_miss_tokens || 0;
  if (hit + miss > 0) parts.push("Cache hit " + ((hit / (hit + miss)) * 100).toFixed(0) + "%");
  if (m.prompt_tokens || m.completion_tokens) {
    parts.push("Input " + fmtTok(m.prompt_tokens) + " tok · Output " + fmtTok(m.completion_tokens) + " tok");
  }
  return parts.join(" | ");
}

export function applyDoneStats(m, evt) {
  var tool = m.liveToolMs;
  var wall = typeof evt.ms === "number" ? evt.ms : liveElapsedMs(m, m.now);
  m.completedSteps += m.liveSteps + 1;
  m.completedToolMs += tool;
  m.completedLlmMs += Math.max(wall - tool, 0);
  if (typeof evt.prompt_tokens === "number") m.prompt_tokens += evt.prompt_tokens;
  if (typeof evt.completion_tokens === "number") m.completion_tokens += evt.completion_tokens;
  if (typeof evt.cache_hit_tokens === "number") m.cache_hit_tokens += evt.cache_hit_tokens;
  if (typeof evt.cache_miss_tokens === "number") m.cache_miss_tokens += evt.cache_miss_tokens;
  if (typeof evt.ttft_samples === "number" && evt.ttft_samples > 0) {
    m.ttft_ms_total += evt.ttft_ms_total || 0;
    m.ttft_samples += evt.ttft_samples;
  } else if (typeof m.liveTtftMs === "number") {
    m.ttft_ms_total += m.liveTtftMs;
    m.ttft_samples += 1;
  }
  m.live = false;
  m.liveStartedAt = 0;
  m.liveToolMs = 0;
  m.liveSteps = 0;
  m.liveTtftMs = null;
  return m;
}
