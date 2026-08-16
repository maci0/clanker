# PRD — Deterministic tool-result pruning

## Status

Shipped. `src/agent/prune.zig` owns the pure UTF-8-safe head/tail rewrite and
reclaim estimate. `Agent.maybeCompactMessages` uses the estimate before its
LLM-summarization branch, while `Agent.requestMessages` prunes a shallow
request copy so the canonical/saved transcript remains exact. Three
`agent.tool_result_prune_*` fields configure it; threshold `0` disables it.
Inspired by
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)'s
`packages/compaction/compaction-tool-result-pruner/`.

## Problem

Clanker compacts a conversation two ways today, both coarse or costly.
`session.compactMessages` (`src/agent/session.zig`, ~488) drops whole
oldest non-system messages, left to right, once the estimated token count
exceeds a budget — cheap, but it can only remove entire messages, never
shrink one. `Agent.maybeCompactMessages` (`src/agent/loop.zig`, ~1200)
replaces the middle of the conversation with an LLM-written summary once
`agent.compact_threshold_bytes` is passed — flexible, but every trigger
costs a real model call. Neither answers a common, narrower case well: one
oversized tool result (a `read_file` on a large file, a verbose `exec`
dump) dominating the byte budget while everything else in the conversation
is still worth keeping as-is. Dropping the whole message loses context that
was fine; paying for a summarizer to solve a problem that is really "one
message is too long" is buying more than the problem needs.

DSH's `compaction-tool-result-pruner` is a proven answer to exactly this
shape: rewrite an over-budget tool result to a bounded head, a fixed
omission marker, and a bounded tail, model-free, leaving every other message
untouched.

## Goals

1. A pure function, `pruneToolResults(messages, threshold_bytes, head_bytes,
   tail_bytes) -> usize` (bytes reclaimed), that scans messages with
   `role == .tool` whose `content.len` exceeds `threshold_bytes` and rewrites
   `content` in place to `head ++ "\n\n[... tool result middle pruned
   ...]\n\n" ++ tail`.
2. UTF-8-safe slicing: the head/tail cut points never split a codepoint.
   Splitting a multi-codepoint grapheme cluster is accepted (documented, not
   solved — DSH accepts the identical limitation).
3. Runs as a cheap first pass inside `Agent.maybeCompactMessages`, before its
   existing LLM-summarization branch: if pruning alone brings the estimated
   size back under budget, the summarizer call is skipped for that turn.
4. New config: `agent.tool_result_prune_bytes` (default 8192),
   `agent.tool_result_prune_head_bytes` (default 4096),
   `agent.tool_result_prune_tail_bytes` (default 1024). `0` on the threshold
   disables pruning entirely.
5. Idempotent: running the function again over an already-pruned result is a
   no-op, since the rewritten content is already under threshold.

## Non-goals

- **Semantic or importance-aware pruning.** Syntactic head/tail only, same
  as DSH — this does not try to keep "the interesting lines," only the
  start and end.
- **Keeping a recoverable copy of the pruned original in memory or on disk
  for later un-pruning.** Once pruned, the original bytes are gone from the
  in-memory request-bound message list. This does not touch
  `state/sessions/*.json` at all (see Design) — the on-disk transcript is
  unaffected by this feature.
- **Pruning non-tool messages.** Assistant and user text are never touched;
  only `role == .tool` content.

## Design

**Prune the request-bound copy, never the saved copy.** This is the one
build blocker this PRD has to settle rather than leave open, because getting
it backwards would make the on-disk session transcript lossy in a way it is
not today. `session.compactMessages`'s existing save-time trim
(`src/agent/session.zig`) drops whole messages from what gets written to
`state/sessions/*.json`; that mechanism is untouched. `Agent.requestMessages`
first makes a shallow copy of the message structs, then `pruneToolResults`
rewrites content only in that request copy. The model pays for less; the
canonical and saved transcript stay exact. A reader of a saved session sees
the tool result clanker actually got, not a pruned stand-in.

**Where it plugs into the pressure check.** `Agent.maybeCompactMessages`
already decides, per turn, whether the estimated size exceeds
`compact_threshold_bytes` and, if so, calls the LLM summarizer. This PRD
subtracts `reclaimableBytes / 4` — the reclaim in bytes, converted to the
token estimate the decision compares — without mutating the canonical
messages. If the request-only rewrite brings the estimate under
budget, the summarizer branch is skipped. Immediately before the provider
call, `requestMessages` makes and prunes the shallow copy described above.

**Byte-boundary safety.** The head cut searches backward from
`head_bytes` for a valid UTF-8 lead-byte boundary; the tail cut searches
forward from `content.len - tail_bytes` the same way. Clanker's existing
codepoint-boundary helpers (already used by `width.zig`/`sanitize.zig` for
similar boundary-safe truncation) are the natural reuse target rather than
writing a third copy of that logic.

**Config validation.** `head_bytes + len(marker) + tail_bytes` must fit
within `threshold_bytes`, checked at config load — a configuration that
cannot shrink an over-budget result (because the kept parts plus the marker
already exceed the threshold) is rejected loudly rather than silently
looping or producing a result larger than what it replaced. This mirrors
the manifest validator's fail-loud rule for an out-of-range `fuel` value
(PRD 0010): a nonsensical config is a load-time error, not a runtime
surprise.

**Dependencies.** None. Sits directly beside existing
`session.compactMessages` / `Agent.maybeCompactMessages`; no new module
gate, no other Draft PRD required.

**Implementation.**

1. `pruneToolResults` (pure, no I/O) with unit tests: UTF-8 boundary cases,
   idempotency on a second pass, exact threshold edge cases (content exactly
   at threshold, one byte over), and the "kept parts don't fit" config
   rejection.
2. `agent.tool_result_prune_bytes` / `_head_bytes` / `_tail_bytes` config
   fields with load-time validation.
3. Call site in `Agent.maybeCompactMessages`, ahead of the summarizer
   branch, with a log line in the existing "[history compacted: ...]" style
   already surfaced by the REPL's turn-stats formatter
   (`src/tui/turn_stats.zig`).
4. Extend the REPL's existing compaction-event detection (`stats.summaryState`
   in `turn_stats.zig`, which currently only recognizes the LLM-summary
   placeholder) to also report bytes reclaimed by pruning as a distinct,
   separately-labeled event — a pruning pass is not a summarization pass and
   should not be reported as one.

## Failure modes

| Condition | Behaviour |
|---|---|
| `tool_result_prune_bytes = 0` | Pruning disabled; `maybeCompactMessages` behaves exactly as it does today |
| A tool result already under threshold | Untouched |
| `head_bytes + marker + tail_bytes >= threshold_bytes` | Config load error; the run does not start with a pruning config that cannot shrink anything |
| Cut point lands mid-codepoint | Boundary search backs off to the nearest valid codepoint start |
| Pruning alone brings the estimate under budget | Summarizer branch is skipped for that turn |
| Pruning does not bring the estimate under budget | Summarizer branch still runs, over the unpruned canonical messages (pruning is request-side, after compaction) |

## Acceptance criteria

- [x] `pruneToolResults` is pure, unit-tested, and never allocates a second
      full copy of an unpruned result once it is done.
- [x] A `role == .tool` message over `tool_result_prune_bytes` is rewritten
      to head + marker + tail, and is under the threshold afterward.
- [x] Assistant and user messages are never modified by pruning.
- [x] `state/sessions/*.json` for a session that triggered pruning contains
      the original, unpruned tool-result content — pruning is provably
      request-side only.
- [x] A second pruning pass over already-pruned content is a no-op (byte
      count unchanged).
- [x] A config where kept parts plus the marker exceed the threshold is
      rejected at load, not at first use.
- [x] When pruning alone relieves compaction pressure, the LLM summarizer is
      not called for that turn (verified via a call counter in tests).

## Open questions / future work

- **Surfacing a pruned result differently in the REPL/web UI.** A visual
  marker on a tool-call card whose result was pruned (versus one that
  wasn't) would help a user understand why a `read_file` result looks
  shorter than the file actually is. Deferred: optional UI polish, not
  required for the mechanism itself to be correct or useful.
