# Bug — improve-self hangs when a provider goes quiet: proposal/plan LLM calls have no deadline

## TL;DR

- **What failed:** `clanker improve-self` printed nothing for 900s and was killed by the autorecover loop's stall-timeout. The improve engine's proposal and plan LLM calls (`src/improve/engine.zig`) used `client.chat` directly with no deadline, so a provider that went quiet blocked the run silently — the same failure as 2026-08-17-agent-llm-call-has-no-deadline, on the one path that fix missed. Fixed with `client.chatWithDeadline`; gates green.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-18. Wrapped both improve-engine LLM calls in client.chatWithDeadline using agent.request_timeout_ms; verified with clanker gate build+tools+test+fmt all passing.

## Status

Resolved on 2026-08-18. Wrapped both improve-engine LLM calls in client.chatWithDeadline using agent.request_timeout_ms; verified with clanker gate build+tools+test+fmt all passing.

## Symptom and impact

An improve-self batch (`clanker/improve-self-1787044014644436071-main`) was
stopped by the autorecover loop with "printed nothing for 900s". Its last log
line was `proposal rejected: UnexpectedEndOfInput` at `ts_ms=1787046814005`,
after which nothing was emitted. The run had earlier logged, in order:

- a rejected staging build (`tools/zig/schedule.zig:157:13: error: error set is discarded` — a bad staged patch that never landed),
- `capability evals: 1 case(s) failed; retrying only those`,
- `improve-self: merging clanker/improve-self-1787044014644436071-main into main conflicts; leaving it on the branch for manual merge`,
- `proposal rejected: UnexpectedEndOfInput`.

The two `http request to 'http://127.0.0.1:9/api/notify' failed: ConnectionRefused`
lines are not a defect: `dummy-down` is the discard-port peer in `config.toml`,
kept deliberately so `phonebook`/`notify` have a reachable-but-refused case.

## Root cause

The improve engine makes its own LLM calls and they were unbounded. Both call
sites used `client.chat` directly:

- `src/improve/engine.zig` proposal request (`fn askModel` / iteration step 2)
- `src/improve/engine.zig` plan request (`fn plan`)

`client.chat` retries transport errors and retryable statuses, but a provider
that accepts the TCP connection and then sends nothing produces no error to
classify — `std.http.Client` has no read timeout and a call that never returns
never returns an error. So the run sat in the proposal/plan call silently until
the autorecover loop's `DEFAULT_STALL_TIMEOUT = 900.0` killed it.

This is the same failure mode as
[`2026-08-17-agent-llm-call-has-no-deadline.md`](2026-08-17-agent-llm-call-has-no-deadline.md),
whose fix added `agent.request_timeout_ms` / `agent.stream_idle_timeout_ms` and
wired them into `chatWithFallbackChain` in the *agent loop*. The improve
engine's own `client.chat` calls were not covered by that change.

The `UnexpectedEndOfInput` line is a symptom, not the cause: it is
`@errorName(err)` from `proposal_mod.parseProposal` failing on truncated JSON
(`src/improve/engine.zig` logs `proposal rejected: {s}`). A truncated/empty
proposal is handled and retried; the hang that produced the 900s silence was the
*next* unbounded proposal call after that rejection.

## Resolution

`src/improve/engine.zig`: both `client.chat(...)` calls are now
`client.chatWithDeadline(..., self.cfg.agent.request_timeout_ms)`.

`chatWithDeadline` is the right wrapper here (over `chatWithTimeout`): it keeps
the request on the caller's thread, so the run's thread-local log context stays
on every provider line the call emits, and it arms the whole-call ceiling. When
the deadline lapses it aborts the request and returns `error.Timeout`, which the
existing `catch` logs as `proposal request failed: Timeout` / `plan request
failed: Timeout` and turns into `error.ProposalRequestFailed` /
`error.PlanRequestFailed` — a clean, logged failure that the run retries or
fails fast instead of hanging.

`request_timeout_ms` defaults to 0 (unbounded) in `src/config.zig`, so a config
that never sets it keeps the previous behaviour; the shipped `config.toml` sets
900000, below the autorecover loop's 900s stall watchdog, so the graceful abort
now wins the race.

## Verification

- `zig build`, `zig build tools`, `zig build test`, `zig fmt --check` all pass
  (via `clanker gate` build+tools+test+fmt).
- The wrapped `chatWithDeadline` already has four unit tests in
  `src/llm/client.zig` driving the real client against a stalling socket; this
  change only routes the improve engine through that tested wrapper.

## Follow-up

- `src/autoresearch/loop.zig:205` still calls `client.chat` with no deadline —
  same hang class, separate subsystem. Not fixed here (out of scope).
- Five stale `clanker/improve-self-*` branches and `.clanker-worktrees/`
  directories remain from killed runs. Their stranded commits are all either
  already promoted to main under a different hash (same `imp-*` id) or moot
  (the `empty_task` check patches `doDiagnose`, which main later trimmed away).
  The sandbox refuses `git worktree remove .clanker-worktrees/...` as a foreign
  worktree, so cleanup is left to the loop's own `cleanup` step or the operator.

## References

- Root-cause sibling: [`2026-08-17-agent-llm-call-has-no-deadline.md`](2026-08-17-agent-llm-call-has-no-deadline.md)
- Code: `src/improve/engine.zig` (`askModel`, `plan`), `src/llm/client.zig` (`chatWithDeadline`, `underDeadline`), `src/config.zig` (`agent.request_timeout_ms`)
## Follow-up 2026-08-20: empty-content recurrence, budget-aware handling

A later batch (`improve clanker tools`, request_id `improve`) again logged
`proposal rejected: UnexpectedEndOfInput` and `model returned no proposal
content` across both iterations, all attempts failed. This time the deadline
worked (no 900s hang) — the failure was the *content*: `deepseek-v4-flash`
(reasoning, `reasoning_effort=low`, `max_tokens=8192`) kept returning either a
truncated JSON object (`UnexpectedEndOfInput` from `parseProposal`) or empty
`content` with the reasoning not containing a `lastProposalJson`-extractable
answer. On a reasoning model `reasoning_content` is output, so a large-context
improve turn spends the grant before the answer and the provider answers 200
with empty content / `finish_reason: length`.

Fix (this change): the improve engine now distinguishes the failure cause. In
the empty-content path it logs `finish_reason`, reasoning length, and raw
length, and when `finish_reason == "length"` it sends budget-aware feedback
("keep reasoning short, put the complete JSON in the content field") instead of
the generic "output the JSON in the content field" that a budget-starved
reasoning model cannot satisfy. The `parseProposal` failure path does the same
for a truncated object instead of the JSON-escaping lecture. The plan phase
logs the same completion shape. Verified with `zig build` / `zig fmt --check`.
