# Investigation — `clanker run` never finishes, compacting on every iteration

## TL;DR

- **Question:** why did a `clanker run` started by the imp-autorecover loop keep
  running past iteration 173 without ever finishing or failing?
- **Finding:** two independent defects compound. Compaction can never get the
  history under its threshold because the immovable part (system message plus
  the six-message tail) is already larger than the threshold, so it fires on
  every iteration forever; and the compaction summary call fails deterministically
  on a thinking model because its 512-token budget is spent entirely on reasoning.
  Both reproduced.
- **Resolution:** handoff. Two bug reports opened; no fix committed yet.

## Status

Investigating. Moves to Resolved when the two linked bugs are fixed and a run
with the same configuration reaches a final answer instead of the iteration cap.

## Trigger and scope

An unattended `scripts/imp-autorecover-loop` session repaired a failed
`improve-self` batch with `clanker run --no-worktree`. That repair run never
returned. The wrapper has no timeout, so the whole loop stalled behind it.

Environment: `config.local.toml` with `default_provider = "deepseek"`,
`deepseek/deepseek-v4-flash` (`context_window = 1048576`, `max_tokens = 8192`,
`reasoning_effort = "low"`, `capabilities = ["thinking", "tool_use"]`),
`agent.max_iterations = 1000`, `agent.compact_threshold_bytes = 0`.

Observed excerpt (`request_id=run-1786776644`, iterations 170-173):

```
[INFO] iteration 170: 1 tool call(s)
[INFO] compacting conversation: 10 messages, ~18364 estimated tokens (threshold 16000)
[WARN] compaction summary failed (EmptyResponse), trying local extractive summary
[INFO] tool-result pruning reclaimed 5882 bytes from the next request
[INFO] iteration 171: 1 tool call(s)
[INFO] compacting conversation: 10 messages, ~18891 estimated tokens (threshold 16000)
[WARN] compaction summary failed (EmptyResponse), trying local extractive summary
[INFO] iteration 172: 1 tool call(s)
[INFO] compacting conversation: 10 messages, ~18870 estimated tokens (threshold 16000)
[WARN] compaction summary failed (EmptyResponse), trying local extractive summary
```

Three things in that excerpt matter. Compaction runs on *every* iteration. The
estimate never drops below the 16000 threshold, and does not trend downward. The
LLM summary fails every time with the same error.

## Evidence

**Observed — the threshold is 16000 and has nothing to do with the model.**
`maybeCompactMessages` (src/agent/loop.zig:1313) derives it as
`min(context_window / 2, max_history_tokens)` then `max(…, max_tokens_per_turn)`.
With this config: `min(524288, 16000) = 16000`, `max(16000, 4096) = 16000`. The
logged threshold matches exactly. A model with a 1,048,576-token window is being
held to a 16,000-token history because `agent.max_history_tokens` defaults to
16000 (src/config.zig:262) and is an absolute cap, not a fraction of the window.

**Observed — compaction can only rewrite the middle.** `compactionKeepStart`
(src/agent/loop.zig:1373) returns `messages.len - recent_tail_messages`, walked
back so a tool_call/tool-result pair is not split; `compactMiddle`
(src/agent/loop.zig:1387) replaces `messages[1..keep_start]` with one summary
message. Message 0 (the system prompt) and the last six messages are structurally
immovable. Nothing checks whether those alone exceed the threshold.

**Reproduced — the immovable part is 88% of the budget.** A mock
OpenAI-compatible endpoint (always answers with one `read_file` tool call; answers
the summary request with empty content) driving the real binary, in a working
directory carrying this repository's `AGENTS.md` (19,461 B) and
`state/learnings.md` (10,270 B):

```
[fake-llm] tool_calls messages=  2 prompt_chars=56215
```

Two messages — the system prompt and `"read the file"` — are 56,215 characters.
By Clanker's own `chars/4` estimator (src/agent/loop.zig:1284) that is ~14,050
tokens of the 16,000 budget, leaving ~1,950 tokens (~7.8 KB) for the entire
conversation, before a single tool result is stored.

**Reproduced — compaction reaches a fixed point and fires forever.** Same setup,
`agent.max_iterations = 14`:

```
iteration 3 → compacting conversation:  9 messages, ~18035 estimated tokens (threshold 16000)
iteration 4 → compacting conversation: 11 messages, ~19371 …
iteration 5 → compacting conversation: 12 messages, ~19513 …
iteration 6 → compacting conversation: 10 messages, ~18278 …
iteration 7 → compacting conversation: 11 messages, ~19435 …
iteration 8 → compacting conversation: 12 messages, ~19543 …
iteration 9 → compacting conversation: 11 messages, ~19496 …
iteration 10 → compacting conversation: 11 messages, ~19496 …
iteration 11 → compacting conversation: 11 messages, ~19496 …
```

Every iteration from the third onward. The estimate converges to a repeated
19,496 — compaction produces exactly the state it started from, then runs again.
This matches the production log's 10-12 messages at ~18-19.5k tokens.

**Reproduced against the live API — the summary is not merely flaky.** Clanker
sends the summary request with `max_tokens = 512` (src/agent/loop.zig:1573) while
`writeSamplingParams` still applies the model's configured `reasoning_effort`
(src/llm/providers/common.zig:54). Replaying that exact request against
`api.deepseek.com` with 12,000 characters of real source as the transcript:

```
finish_reason: length
content len: 0 | reasoning len: 1978
reasoning_tokens: {'reasoning_tokens': 512}
```

All 512 tokens went to reasoning, content came back empty, so
`summarizeMessages` returns `error.EmptyResponse` (src/agent/loop.zig:1575) —
deterministically, not intermittently. A second replay with an easier, repetitive
transcript spent 438/512 on reasoning and returned 250 characters cut mid-word
with `finish_reason: length`, which the code accepts as a good summary.

**Observed — the cost of each pointless compaction.** In the production log the
gap between the compaction line and the following iteration is 4.4-6.3 s, spent
on the summary round trip that always fails. Over the ~170 iterations before the
run was noticed, that is the dominant share of wall-clock time.

**Inferred — why the agent appeared to spin.** Compaction discards everything
except the system message and the last six messages, so at every iteration the
agent loses what it just learned. The interleaved prose in the log
("Let me find the actual test definition", "Let me run the failing test directly",
"Test passes now. Let me check the git state") is the same investigation being
restarted, which is consistent with a six-message memory but is not directly
proven by the log.

## Hypotheses and tests

| hypothesis | test | result |
|---|---|---|
| The provider hung or rate-limited the run | production log shows steady iteration progress and tool results throughout | rejected — the run was working, just not progressing |
| `EmptyResponse` is a transient provider fault | replayed the exact summary request against the live API twice | rejected — deterministic; the reasoning budget consumes the whole allowance |
| Compaction is merely frequent because history is large | mock-provider reproduction; estimate converges to a repeated 19,496 | confirmed as a fixed point, not a frequency problem |
| The tool-result pruner should have absorbed this | `requestMessages` (src/agent/loop.zig:1357) prunes a per-request *copy*; the stored history keeps every byte, and reclaimable bytes are already discounted from the compaction estimate (src/agent/loop.zig:1316) | rejected — pruning is working as designed and cannot shrink the stored tail |
| The existing repeat-tool loop guard should have caught it | `loop_guard.observe` (src/agent/loop.zig:920) keys on identical tool name plus arguments and only emits a reminder | rejected — the calls varied (`repo_search`, `read_file`, `test_file`, `git`), and the guard never aborts |

## Finding

The run was not hung: it was livelocked, making LLM calls and tool calls forever
without being able to finish.

Compaction has no notion of a floor it cannot move. When
`system + last-six-messages ≥ threshold`, `compactionKeepStart` still reports
"compaction needed", `compactMiddle` still rewrites a middle that is by then a
single summary message, and the result is the same size as the input. Nothing
compares the post-compaction estimate with the pre-compaction one, so the
condition that guarantees no progress is also the condition that triggers a
retry — every iteration, until `agent.max_iterations` (1000 here) is exhausted.

That floor was reached because `agent.max_history_tokens` is an absolute 16000
while this repository's system prompt is ~14,050 tokens on its own. The model's
own 1,048,576-token window is irrelevant to the calculation.

The failing summary is a separate defect on the same path. It does not cause the
livelock — the extractive fallback keeps compaction working — but it pays a full
LLM round trip per iteration for nothing, and it discards the `reasoning_content`
that actually holds the summary.

## Resolution or handoff

Two bugs, fixable independently:

- [Compaction cannot shrink an immovable history](../bugs/2026-08-16-compaction-cannot-shrink-immovable-history.md)
- [Compaction summary budget is spent on reasoning](../bugs/2026-08-16-compaction-summary-budget-spent-on-reasoning.md)

Smallest next change for the livelock: make compaction compare its own result
against its input and refuse to retry when it did not help — an explicit
`compaction made no progress` warning naming the immovable floor, plus a
growth-based cooldown so the next attempt waits until the history has actually
grown. Regression test: the pure `compactionKeepStart` / `compactMiddle` pair
against a message list whose system message alone exceeds the threshold, asserting
the second attempt is suppressed.

Separately, an unattended wrapper must not be able to wait forever on a child;
`scripts/imp-autorecover-loop/loop.py` has no timeout on the repair run it starts.
That is wrapper work, not a Clanker defect, but this incident is the argument for
it.

## References

- Related bugs: [compaction floor](../bugs/2026-08-16-compaction-cannot-shrink-immovable-history.md),
  [summary budget](../bugs/2026-08-16-compaction-summary-budget-spent-on-reasoning.md)
- Code: `src/agent/loop.zig` (1284, 1313, 1357, 1373, 1387, 1531), `src/config.zig` (245, 262),
  `src/llm/providers/common.zig` (46, 54), `src/llm/providers/openai.zig` (223-278)
- Logs or run: production excerpt `request_id=run-1786776644` (iterations 170-173),
  quoted above; mock-provider reproduction described under Evidence
