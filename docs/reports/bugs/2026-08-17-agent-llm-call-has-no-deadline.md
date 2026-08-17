# Bug — An agent run hangs forever when a provider accepts the connection and goes quiet

## TL;DR

- **What failed:** The agent's own completion call ran with no deadline, so a provider that accepted the TCP connection and then sent nothing blocked the run indefinitely: std.http.Client has no read timeout, cancellation cannot reach a thread parked in a read on an established connection, and no retry fires because a call that never returns never produces an error. Fixed by agent.request_timeout_ms and agent.stream_idle_timeout_ms, enforced by a watchdog on a worker thread while the request stays on the caller's.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-17. Fixed on 2026-08-17 by agent.request_timeout_ms and agent.stream_idle_timeout_ms, enforced by a watchdog on a worker thread while the request stays on the caller's; gate 8/8, 1164 unit tests green, four of them driving the real client against a stalling socket.

## Status

Resolved on 2026-08-17. Fixed on 2026-08-17 by agent.request_timeout_ms and agent.stream_idle_timeout_ms, enforced by a watchdog on a worker thread while the request stays on the caller's; gate 8/8, 1164 unit tests green, four of them driving the real client against a stalling socket.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Symptom and impact

An imp-autorecover repair run (`run-1786960106`, log `/tmp/clanker-repair-50srrbd_.log`,
44 lines) stopped mid-run. Its last line is the request build for iteration 8 at
17:49:05.685; there is no answer, no error and no exit line, and no repair
process was alive three minutes later. A hung clanker goes silent, so the
wrapper's `--stall-timeout` is what ends it — unverified for this run, but it is
the only mechanism present that would.

The operator-visible symptom is misleading. The last repeating line is

    tool-result pruning reclaimed 27741 bytes from the next request (1 spilled)

byte-identical on every iteration, which reads like a stuck loop. It is not:
pruning is request-only, so `requestMessages` dupes the pristine history and
prunes the copy each turn, giving the same number for the same message. The
arithmetic accounts for it exactly — a 404,360-byte `read_file` result capped by
`capToolResult` to 32768 + a ~132-byte notice, less 4096 head + 39 marker + 1024
tail kept, is 27,741; iteration 7's 11,534-byte read adds 6,375 for the logged
34,116.

## Root cause

The agent's turn goes through `chatWithFallbackChain` (`src/agent/loop.zig`) to
`client.chatStream` or `client.chat`, and neither took a deadline.
`client.chatWithTimeout` already existed but had only two callers, both fail-open
side channels: `src/agent/thinking.zig` and `src/agent/advisor.zig`. No
`[agent]` key bounded the main completion.

Nothing below the loop could end the wait either, as `client.Abort`'s own
comment records: `std.http.Client` has no read timeout
(`ConnectTcpOptions.timeout` is declared and never referenced), and
`Io.Future.cancel` cannot rescue a thread blocked on an established connection —
the canceller wedges alongside it. Retries do not apply: `chat` and
`chatStream` retry every transport error and retryable status, but a call that
never returns produces no error to classify.

## Resolution

Two clocks, because a stream has two ways to stop, both defaulting to 0
(unbounded, previous behaviour) and both set in the shipped `config.toml`:

- `agent.request_timeout_ms` (900000) — one non-streaming call end to end, and
  the wait for a streaming one's first bytes.
- `agent.stream_idle_timeout_ms` (120000) — the gap between reads once a stream
  is flowing. Separate because a healthy stream can run past any whole-call
  ceiling; what it does not do is fall silent mid-answer.

Both clocks must be armed. `chatStream` reads with `readSliceShort`, which
returns only on a full 8 KiB buffer or end of stream, so a provider that emits
less than one buffer and then stops never completes a read and is
indistinguishable from one that never answered — that case belongs to the
first-byte clock.

`Timeout` is not retried against the same provider: the same silent endpoint
would cost a second full deadline before any recovery. It goes to
`agent.fallback_providers`, which is the retry, and it retries elsewhere.

The watchdog runs on an `io.concurrent` worker and the **request stays on the
caller's thread**. The first draft had this backwards, and it was wrong for a
reason worth recording: `on_delta` reads three threadlocals — `stream_tally`
and `ttsr_guard` in the agent loop, `run_stream_socket` in `cli.zig` — and log
context is a fourth, so streaming from a worker would have silently stopped
rendering tokens, blinded the TTSR guard, and left the fallback chain believing
no content had arrived. `client.zig` gained `chatWithDeadline` and
`chatStreamWithTimeout` on that arrangement; `chatWithTimeout` is unchanged for
its callback-free callers.

## Verification

`clanker gate` 8/8 on the combined tree, and the unit binary run directly:
1164 passed, 5 skipped, 0 failed. Four tests drive the real client against a
real socket:

- `bounded stream aborts a provider that sends nothing at all` — first-byte
  clock only; logs `sent nothing for 300ms`.
- `bounded stream abandons a stream that starts and then goes quiet` — idle
  clock only, and asserts the delta callback ran on the calling thread, which is
  what pins the arrangement above. Logs `went quiet mid-stream for 300ms`.
- `a deadlined non-streaming call keeps the request on the calling thread` —
  logs `did not answer within 300ms`.
- `agent request deadlines and the repeat abort threshold parse and default to
  off`.

`clanker --dump-config` shows `request_timeout_ms = 900000` and
`stream_idle_timeout_ms = 120000` reaching `agent`.

Found while writing the first draft of the streaming test, and worth its own
note: a mock that sent two SSE frames and then went quiet hung `zig build test`
outright (test 180 of 1163, two test binaries sitting at ~0 CPU). The cause is
the same `readSliceShort` property — the read never completed, so the counter
never moved and the only armed clock was the disabled one. The mock now sends
more than one read buffer before stalling.

## Follow-up

Filed, not fixed: `ck_fs_stat` gained `mtime_ms` here only because spill ids are
content hashes and carry no order; nothing else consumes it yet.