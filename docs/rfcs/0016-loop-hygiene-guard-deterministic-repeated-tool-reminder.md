# RFC 0016 — Loop-hygiene guard: deterministic repeated-tool reminder

## Status

Decided — 2026-08-17. ADR 0028

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

DeepSeek Harness repeat-tool-reminder is a zero-cost deterministic nudge for repeated identical tool calls (distinct from priced Advisor). Decide whether to adopt it as a non-LLM reminder in clanker's agent loop.

**Decision to make.** Which deterministic loop-hygiene guard should clanker adopt for repeated identical tool calls (distinct from Advisor's priced LLM review), and where should it run?

**Why now.** ROADMAP Planned (DeepSeek/DSH audit) and PRD 0029 describe a zero-cost hygiene guard; RFC 0009/0010/0011 already covered REPL gaps, but loop hygiene has no RFC→ADR trail yet.

**Drivers.** Zero-cost until threshold, advisory-only, canonical JSON match, configurable thresholds/excludes, reuse existing `Agent.executeCalls` gate.

**Out of scope.** Fuzzy matching and blocking at high thresholds (both deferred in PRD 0029); cross-agent sharing.

## Current state

Today: `src/agent/loop_guard.zig` and wiring in `src/agent/loop.zig:Agent.executeCalls` exist as a shipped PRD 0029 implementation; `agent.repeat_tool_thresholds`/`repeat_tool_exclude` config is parsed and validated. This RFC documents the decision that led there; alternative paths are recorded for traceability.

## Options considered

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

### Option A — Deterministic canonical chain in `LoopGuard` with thresholds [3,5,8] + excludes

- **What it is:** Deep key-sorted JSON canonicalization + run-length chain; inject one reminder at each threshold before the next request; advisory-only.
- **Maturity:** Matches DSH `repeat-tool-reminder` semantics; proven zero-cost.
- **How it would fit:** `src/agent/loop_guard.zig` pure module + `src/agent/loop.zig` injection; `src/config.zig` thresholds with loud validation.
- **Pros:** No LLM cost; exact-match avoids false positives; excludes keep bookkeeping calls transparent.
- **Cons:** Near-duplicates evade detection.
- **Cost to adopt:** Small pure module + wiring.
- **Cost to leave:** Remove guard and config knobs.
- **Evidence:** `src/agent/loop_guard.zig` — verified in tree; PRD 0029 Goals 1-5 satisfied.

### Option B — Use Advisor's LLM review for loop hints

- **What it is:** Let the priced advisor notice repeats.
- **Maturity:** Advisor exists but is `enabled=false` default.
- **How it would fit:** No guard; rely on second model.
- **Pros:** Could catch fuzzy loops.
- **Cons:** Costly; latent; overkill for string equality.
- **Cost to adopt:** None.
- **Cost to leave:** None.
- **Evidence:** `src/agent/advisor.zig` exists — verified.

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

- **If A:** Identical-loop nudges land immediately; zero cost for normal runs.
- **If B:** Advisor must be enabled to notice loops; priced.
- **If C:** No guard; loops spend full budgets.

### Medium term (3–12 months)

- **If A:** Tuning of thresholds/excludes from telemetry becomes cheap.
- **If B:** Advisor tuning conflated with loop tuning.
- **If C:** Same.

### Long term (12+ months)

- **If A:** Stable hygiene; easy to extend or disable.
- **If B/C:** Either pay for hygiene or do without.

## Recommendation

**Recommended option:** Adopt Option A — deterministic canonical chain with thresholds [3,5,8] and excludes (advisory-only)

**Confidence:** 8/10

**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._

**Rationale.** Zero-cost exact-match guard complements priced Advisor; pure canonicalization and bounded injection fit the existing executeCalls gate without blocking.

**Reversibility.** _How hard is this to undo, and where is the point of no return?_

## Open questions

- Whether fuzzy/near-duplicate detection is ever warranted — deferred pending evidence.

## Next steps / action items

- [ ] ADR 00XX linking this RFC; PRD 0029 already Shipped.

## References



- Related ADRs, PRDs, reports, and prior RFCs.
- External sources, each with what it supports.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
