# Bug — compaction repeats forever when the history it cannot move exceeds the threshold

## TL;DR

- **What failed:** a `clanker run` compacted its conversation on every iteration
  without ever getting under the threshold, and ran until the iteration cap
  instead of finishing.
- **Impact:** any run whose system prompt plus six-message tail exceeds
  `agent.max_history_tokens`. With this repository's own prompt and the default
  16000-token cap, that is every long run. Each wasted iteration also costs an
  extra LLM round trip and erases the agent's working context.
- **Resolution:** resolved in `d2628464`. The threshold now answers to what
  compaction can actually deliver, and a run pinned against its ceiling stops
  with `error.CompactionStalled` instead of spinning.

## Status

Resolved. Established by
[Investigation — `clanker run` never finishes](../investigations/2026-08-16-run-livelock-compaction-thrash.md);
verified against that investigation's reproduction.

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

Fixed in `d2628464` (`src/agent/loop.zig`, `src/cli.zig`), in three parts.

**The threshold answers to what compaction can deliver.** `immovableTokens`
measures what survives a compaction — the system message, the kept tail, and the
summary written back in place of the middle — and `raisedThreshold` lifts a
configured threshold below that floor up to the floor plus half again of
headroom, bounded by the model's own context budget. `agent.max_history_tokens`
still caps history; it can no longer demand the impossible. The lift is reported
once per run:

```
[WARN] history threshold 16000 is below the 20774 tokens compaction cannot
       remove (system prompt plus the 6 kept messages); using 31161 for this run
```

**One definition of what the history costs.** `historyTokens` is now the single
measure used by the threshold test, the immovable floor, and the before/after
check. This mattered: the first version of the fix sized a tool result at full
length for the floor and at its pruned length for the estimate, which overstated
the floor by a factor of two (41,579 against the true 20,774) and raised the
threshold far higher than needed.

**A pinned run ends.** The stop condition is `max_consecutive_compactions` (5)
iterations that each needed a compaction, not a per-compaction progress share.
The share was tried first and does not work: with a threshold barely above the
floor, each compaction genuinely frees ~6% and dips just under, then one
iteration puts the history back over, so every individual compaction "succeeds"
while the run compacts on every iteration. Consecutive compactions catch that
shape and the freed-nothing shape alike. The run then fails with
`error.CompactionStalled`, which `reportUnfinishedRun` treats as an outcome
rather than a crash and which names both ceilings, since raising the cap only
helps when the model has the room:

```
[ERROR] run could not compact its history any further and did not produce a final answer
[INFO]  agent.max_history_tokens is 16000 and this model gives compaction 20000
        tokens to work in (half of a 40000 context window)
```

Operationally, `agent.max_history_tokens` should still be set well clear of the
system prompt — the fix keeps a run alive and honest, it does not make a 16000
cap a good setting for a 1M-token model.

## Verification

Against the reproduction above, with the fixed binary:

| scenario | before | after |
|---|---|---|
| 1,048,576-token model, 14 iterations | compaction on 12 of 14 iterations, estimate pinned at a repeated 19,496 | one compaction, at iteration 13, when the history genuinely reached 32,013 |
| 40,000-token model (floor unreachable) | compaction every iteration to the iteration cap | five consecutive compactions, then `CompactionStalled`, exit 1 |

The floor line appears once per run, not per iteration. The stalled run exits
non-zero promptly, which is what lets a supervising wrapper react.

Unit tests in `src/agent/loop.zig`: `raisedThreshold` (raises below the floor,
keeps headroom, respects the model budget, leaves an adequate threshold
untouched), `immovableTokens` (counts system + tail + reserve, discounts what
pruning would strip, excludes the droppable middle), and `compactionSucceeded`
(a compaction that leaves the history over the threshold has not succeeded).
Full suite on the merged tree: 1063 passed, 5 skipped, 0 failed.

## Follow-up

`scripts/imp-autorecover-loop/loop.py` waited on its repair run with no timeout,
which is why this defect stalled an unattended loop for hours rather than being
noticed quickly. It now has a watchdog (a wall-clock cap on repair-level runs, a
silence timeout on every run), which covers every other way a child can fail to
return, including the next unknown one.

Remaining risk: `agent.max_history_tokens` still defaults to a flat 16000 with no
relation to the model's context window. The fix makes that harmless rather than
fatal — a run lifts the threshold and says so — but a default that is wrong for
every large-window model is still a default worth revisiting, together with a
config-validation warning when the system prompt approaches the cap.

## References

- Investigation: [`2026-08-16-run-livelock-compaction-thrash.md`](../investigations/2026-08-16-run-livelock-compaction-thrash.md)
- Runbook: [Agent run compaction thrash](../../runbooks/agent-run-compaction-thrash.md) —
  the current recovery procedure for an operator who meets the symptom
- Documentation: [History budget and compaction](../../configuration.md#history-budget-and-compaction)
- Code: `src/agent/loop.zig` (`maybeCompactMessages`, `historyTokens`, `immovableTokens`,
  `raisedThreshold`, `compactionSucceeded`, `CompactionState`), `src/cli.zig`
  (`reportUnfinishedRun`), `src/config.zig` (`max_history_tokens`)
- Fix: `d2628464` (with `da32e5a0`, `0a8e904e`, merge `b5950374`)
