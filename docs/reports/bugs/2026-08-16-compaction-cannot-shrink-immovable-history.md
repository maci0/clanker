# Bug — compaction repeats forever when the history it cannot move exceeds the threshold

## TL;DR

- **What failed:** a `clanker run` compacted its conversation on every iteration
  without ever getting under the threshold, and ran until the iteration cap
  instead of finishing.
- **Impact:** any run whose system prompt plus six-message tail exceeds
  `agent.max_history_tokens`. With this repository's own prompt and the default
  16000-token cap, that is every long run. Each wasted iteration also costs an
  extra LLM round trip and erases the agent's working context.
- **Resolution:** open. Cause confirmed and reproduced; no fix committed.

## Status

Open. Established by
[Investigation — `clanker run` never finishes](../investigations/2026-08-16-run-livelock-compaction-thrash.md).

## Symptom and impact

A repair run started by `scripts/imp-autorecover-loop` passed iteration 173 with
no sign of finishing. Its log repeats one shape per iteration:

```
[INFO] iteration 171: 1 tool call(s)
[INFO] compacting conversation: 10 messages, ~18891 estimated tokens (threshold 16000)
[WARN] compaction summary failed (EmptyResponse), trying local extractive summary
```

The estimate never falls below the threshold and does not trend down. With
`agent.max_iterations = 1000` the run would have continued for hours before
failing with "hit the iteration limit without a final answer". The wrapper that
started it waits on the child with no timeout, so the whole autorecover loop
stalled behind this one run.

Beyond the wasted time, each compaction discards everything except the system
message and the last six messages, so the agent repeatedly loses what it just
established and re-derives it.

## Reproduction

Reliable, with the real binary and no API key.

Preconditions: a working directory containing this repository's `AGENTS.md`
(19,461 B) and `state/learnings.md` (10,270 B), so the system prompt is
production-sized; `agent.compact_threshold_bytes = 0`;
`agent.max_history_tokens` left at its 16000 default; a model whose
`context_window` is large (1048576 here, so the window never binds).

Steps: point a provider at a mock OpenAI-compatible endpoint that always answers
with one `read_file` tool call against a ~44 KB file, and run
`clanker run --no-worktree "read the file"`.

Expected: compaction runs occasionally and the estimate drops below 16000 after
each one.

Actual: compaction runs on every iteration from the third onward, and the
estimate converges upward to a fixed point:

```
iteration  3 → compacting conversation:  9 messages, ~18035 estimated tokens (threshold 16000)
iteration  6 → compacting conversation: 10 messages, ~18278 …
iteration  9 → compacting conversation: 11 messages, ~19496 …
iteration 10 → compacting conversation: 11 messages, ~19496 …
iteration 11 → compacting conversation: 11 messages, ~19496 …
```

The same mock endpoint reports the size of the immovable part directly: the very
first request, carrying only the system message and the user task, is 56,215
characters — ~14,050 tokens by Clanker's own `chars/4` estimator
(src/agent/loop.zig:1284), or 88% of the 16,000-token budget.

## Root cause

Two facts combine.

**Compaction can only rewrite the middle.** `compactionKeepStart`
(src/agent/loop.zig:1373) preserves `messages[0]` (the system prompt) and the last
`recent_tail_messages = 6`, and `compactMiddle` (src/agent/loop.zig:1387)
replaces `messages[1..keep_start]` with a single summary message. Once the middle
is already one summary, a further compaction removes essentially nothing.

**The threshold is unrelated to the model's capacity.**
`maybeCompactMessages` (src/agent/loop.zig:1313) computes
`min(context_window / 2, agent.max_history_tokens)`, then raises it to at least
`agent.max_tokens_per_turn`. `agent.max_history_tokens` defaults to 16000
(src/config.zig:262) and is an absolute number, so a 1,048,576-token model is
held to 16,000 tokens of history. A ~14,050-token system prompt then leaves about
1,950 tokens for the whole conversation.

When `system + tail ≥ threshold`, the compaction decision is permanently true and
the compaction result is permanently insufficient. Nothing in the path notices:
the post-compaction estimate is returned to the caller (src/agent/loop.zig:1354)
but never compared with the pre-compaction estimate, there is no cooldown between
attempts, and `run()`'s only stop is `iteration < self.max_iterations`
(src/agent/loop.zig:666). The condition that guarantees no progress is the same
condition that schedules the next attempt.

Ruled out as causes, with evidence in the investigation: tool-result pruning
(works as designed, prunes a per-request copy, and its reclaimable bytes are
already discounted from the estimate at src/agent/loop.zig:1316); the repeat-tool
loop guard (keys on identical tool calls and only warns); the failing summary
call (a separate defect — the extractive fallback keeps compaction functioning).

## Resolution

Not yet implemented. The changes that address the root cause, smallest first:

1. **Detect no-progress compaction.** Compare the post-compaction estimate with
   the pre-compaction one. When it did not fall materially, log once — naming the
   immovable floor, e.g. "system prompt ~14050 tokens of a 16000 threshold" —
   and suppress further attempts until the history has grown by a margin beyond
   the last attempt. This alone converts a livelock into a run that proceeds.
2. **Make the threshold answer to the model.** Treat `max_history_tokens` as a
   ceiling that cannot fall below what the immovable part needs, or scale it with
   `context_window` so a 1M-token model is not capped at 16k. Validation should
   warn when the system prompt approaches the configured cap.
3. **Give a hopeless run a defined end.** After N consecutive no-progress
   compactions, abort with a distinct error rather than burning to
   `max_iterations`, so a supervising wrapper sees a non-zero exit promptly.

Operationally, until a fix lands, raise `agent.max_history_tokens` in
`config.local.toml` to something well clear of the system prompt (for a 1M-token
model, 100000+ is reasonable) and keep `state/learnings.md` trimmed.

## Verification

Pending. The fix must show, on the reproduction above: compaction attempted at
most once per growth window rather than every iteration; an explicit log line
naming the immovable floor; and the run reaching a final answer or a clear
failure instead of the iteration cap. A unit test over `compactionKeepStart` and
`compactMiddle` with a system message that alone exceeds the threshold should
assert the second consecutive attempt is suppressed.

## Follow-up

`scripts/imp-autorecover-loop/loop.py` waits on its repair run with no timeout,
which is why this defect stalled an unattended loop rather than being noticed
quickly. A watchdog there is worth having regardless of this fix, since it covers
every other way a child can fail to return.

## References

- Investigation: [`2026-08-16-run-livelock-compaction-thrash.md`](../investigations/2026-08-16-run-livelock-compaction-thrash.md)
- Code: `src/agent/loop.zig` (1284, 1313, 1354, 1373, 1387, 666), `src/config.zig` (262)
- Fix: none yet
