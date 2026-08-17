# RFC 0017 — Deterministic tool-result pruning (bounded head/marker/tail)

## Status

Decided — 2026-08-17. ADR 0029

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

DSH compaction-tool-result-pruner rewrites one oversized tool result to head/marker/tail without an LLM call. clanker's LLM-summarizer dominates cost for one bulky result. Decide whether to add a deterministic pruner before summarization.

**Decision to make.** Which deterministic pruning strategy for one oversized tool result (bounded head/marker/tail) should clanker adopt as a cheap pre-pass before LLM summarization?

**Why now.** ROADMAP Planned (DSH/DeepSeek Harness) and PRD 0031 describe deterministic pruning as the next cost-saving compaction step; no RFC→ADR trail exists yet.

**Drivers.** Pure, bounded rewrite; config-gated (`0` disables); request-copy only so saved transcript stays exact; UTF-8 safe; zero LLM cost when it fires.

**Out of scope.** Spill/session-scoped locators (follow-up), importance-aware pruning.

## Current state

Today: `Agent.maybeCompactMessages` summarizes the middle of the conversation via LLM; no quick prune of a single bulky tool result exists. `src/agent/prune.zig` is the intended site per PRD 0031.

## Options considered

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

### Option A — Bounded head/marker/tail on a request copy before summarizer (PRD 0031)

- **What it is:** Pure `pruneToolResults` rewrites one `role=tool` result over `threshold` to `head + marker + tail`; runs inside `maybeCompactMessages` and over a shallow request copy; threshold `0` disables.
- **Maturity:** PRD 0031 Shipped; `src/agent/prune.zig` exists with UTF-8 cuts and reclaim estimate.
- **How it would fit:** `src/agent/prune.zig` + `src/agent/loop.zig` + `src/config.zig` (`tool_result_prune_*`) + `src/agent/prune.zig` host-tested helper; no WASM.
- **Pros:** Cheapest fix for one bulky result; preserves rest of conversation; skips summarizer when enough reclaimed.
- **Cons:** Syntactic head/tail only; not importance-aware.
- **Cost to adopt:** Small pure function + plumbing.
- **Cost to leave:** Remove call and config.
- **Evidence:** `src/agent/prune.zig` — verified.

### Option B — Always summarize via LLM

- **What it is:** Let `maybeCompactMessages` summarize regardless of a quick prune.
- **Maturity:** Current behaviour.
- **How it would fit:** No change.
- **Pros:** No new code.
- **Cons:** Pays LLM even when a single truncation would suffice.
- **Cost to adopt:** None.
- **Cost to leave:** None.
- **Evidence:** `src/agent/loop.zig:maybeCompactMessages` — verified.

### Option C — Status quo

- **What it is:** keep doing what we do today.
- **Pros:**
- **Cons:**
- **Cost to adopt:** zero now; state what it costs later.
- **Evidence:**

## Implications by horizon

What following each candidate means over time. Where the options differ only in
one horizon, say so — that is usually the deciding fact.

### Short term (this release / 0–3 months)

- **If A:** Bulky read_file/exec results shrink cheaply; fewer summarizer calls.
- **If B:** Every compaction pays LLM cost.
- **If C:** Same.

### Medium term (3–12 months)

- **If A:** Tuning of head/tail/marker and threshold from telemetry.
- **If B/C:** Repeated summarizer spend where a trim would do.

### Long term (12+ months)

- **If A:** Stable; easy to keep or disable per config.
- **If B/C:** Persistent cost overhead.

## Recommendation

**Recommended option:** Adopt Option A — bounded head/marker/tail on a request copy before LLM summarization

**Confidence:** 8/10

**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._

**Rationale.** Avoids LLM summarizer cost for one bulky tool result, keeps saved transcript exact, and degrades to no-op when disabled.

**Reversibility.** _How hard is this to undo, and where is the point of no return?_

## Open questions

- Whether visual marking of pruned tool cards in UI is worth adding — deferred as polish.

## Next steps / action items

- [ ] ADR 00XX; PRD 0031 already Shipped — link this RFC to that PRD.

## References



- Related ADRs, PRDs, reports, and prior RFCs.
- External sources, each with what it supports.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
