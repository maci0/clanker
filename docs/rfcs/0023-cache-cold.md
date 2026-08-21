# RFC 0023 — How clanker warns that Anthropic prompt cache has gone cold

## Status

Decided — 2026-08-21. ADR 0035

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Anthropic's prompt cache expires after five minutes idle. clanker already parses cache_read_input_tokens but never clocks idle time, so a cache miss after a pause is silent and expensive. Decide whether and how to warn.

**Decision to make.** How does clanker warn that Anthropic prompt cache has gone cold after idle, and that a miss was unexpected?

**Why now.** A pause over five minutes silently burns a full prompt on the next Claude turn. We already parse cache_read_input_tokens and show a cache segment, so the miss is visible after the fact, not before. jcode inventory: docs/research/jcode-features.md.

**Drivers.** No daemon (ADR 0008): a timestamp compare at request time, not a background warmer. Provider-kind gate: do not switch on kind outside src/llm/providers/. Anthropic's 5 min TTL is a constant we may have to retune. REPL and clanker run both show turn_stats.

**Out of scope.** Prompt-cache pinning / prefix stability (autolearn already advises that). Warming the cache with a dummy request. Non-Anthropic TTLs beyond a configurable override.

## Current state

src/llm/providers/anthropic.zig maps cache_read_input_tokens into usage. src/tui/turn_stats.zig prints a cache segment when the provider reported accounting; omitted rather than 0%. Nothing stores last-success time per provider/model. A 6-minute pause then a turn looks like any other miss. Files: a pure helper (cache_cold.zig or tokens.zig), a stamp at the client choke point (state/token_stats.jsonl already appends per completion), turn_stats / log line before send.

## Options considered

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

### Option A — Stamp last Anthropic success; warn when idle exceeds TTL

What it is: a pure cacheCold(last_ok_ms, now_ms, ttl_ms) helper. Stamp last success at the client choke point (token_stats already records provider/model). Before the next Anthropic request, if idle > ttl (default 300s), log a diagnostic and include a marker on the turn_stats line. After the response, if cache_hit is 0 and we expected a warm cache, log unexpected miss.

Maturity: jcode UI warns; we already have the usage fields.

How it would fit: src/llm/cache_cold.zig (host-tested) + stamp in src/llm/client.zig without switching on ProviderKind (ttl lives on the provider vtable or a config default of 300s applied when usage has cache accounting). REPL/run print the warning through turn_stats.

Pros: no daemon; unit-testable; uses existing usage parse.

Cons: 300s is Anthropic-specific; a provider with a different TTL needs a config override (phase 2).

Cost to adopt: helper + stamp + one log/turn_stats field. Cost to leave: stop stamping.

Evidence: jcode README Misc; PRD 0005 cache segment; anthropic.Usage.

### Option B — Warm the cache with a dummy request at 4 minutes

What it is: a timer sends a tiny completion to keep the prefix hot.

How it would fit: needs a loop. ADR 0008 forbids a daemon; schedule run-due is minute-granularity and would still spend tokens.

Pros: miss never happens.

Cons: burns tokens to save tokens; cannot live in serve without a new thread; contradicts ADR 0008.

Cost to adopt: a scheduler entry plus a hidden completion. Cost to leave: cancel the entry.

Evidence: ADR 0008.

### Option C — status quo

What it is: show cache% after the turn, never before.

Pros: no false warnings.

Cons: the expensive miss is discovered after it is paid.

Cost to adopt: zero; operators learn to poke the session before 5 min.

Evidence: turn_stats omits cache when unreported.

### Option D — out of the box: clanker stats after the fact

What it is: token_stats.jsonl already has cache_hit/miss; clanker stats could flag miss streaks.

How it would fit: model_stats guest.

Pros: no request-path change.

Cons: not a pre-send warning; does not prevent the miss.

Cost to adopt: a stats row. Cost to leave: drop the row.

Evidence: src/stats/tokens.zig.

## Implications by horizon

What following each candidate means over time. Where the options differ only in
one horizon, say so — that is usually the deciding fact.

### Short term (this release / 0–3 months)

If A: a pause over 5 min is named before the next Claude turn. If B: forbidden by ADR 0008. If status quo: miss stays silent until the bill. If D: operators grep stats after the fact.

### Medium term (3–12 months)

If A: per-provider ttl_ms on config if another vendor documents a different window. If B: a hidden warmer becomes a token leak.

### Long term (12+ months)

If A: the helper stays even if Anthropic changes the number. If status quo: people keep learning the 5 min rule the expensive way.

## Recommendation

**Recommended option:** Option A: stamp last success and warn when idle exceeds TTL; log unexpected misses

**Confidence:** 8/10

**Why this confidence.** What the score is resting on, and what would move it:
the specific evidence that would raise it, and the finding that would sink the
recommendation entirely.

**Rationale.** No daemon, uses usage we already parse, unit-testable. Warming contradicts ADR 0008. Stats-after-the-fact does not prevent the miss.

**Reversibility.** How hard it is to undo, and the point of no return (a
migrated data format, a public API, a dependency baked into the build).

## Open questions

Questions whose answers could change the recommendation, each with who or what
can answer it. Keep them here until they are answered; do not silently drop the
ones that turned out to be inconvenient.

## Next steps / action items

- [ ] What happens if this recommendation is accepted, in order.
- [ ] The experiment or spike that would settle an open question above.
- [ ] Who is being asked for comment, and by when.
- [ ] Write the ADR once the decision is made.

## References



- Research: [jcode feature inventory](../research/jcode-features.md).
- ADR 0008 (no daemon). PRD 0005 cache segment. jcode README Misc (opened 2026-08-21).

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
