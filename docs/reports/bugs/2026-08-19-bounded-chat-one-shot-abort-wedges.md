# Bug — A lapsed chat deadline can wedge the caller forever: the abort fires once and cancel cannot rescue a blocked read

## TL;DR

- **What failed:** chatWithTimeout triggered Abort once at the deadline, then future.cancel. A trigger landing before the worker armed the abort (or pooled its connection) shuts down nothing; the worker parks in a read cancel cannot rescue, wedging the caller at 0% CPU. Same one-shot shape in DeadlineWatch.watch; retry loops also reopened connections after a deliberate abort. Fix: latch Abort.triggered, refuse post-abort retries, retrigger every 250ms until the request reports done.
- **Impact:** `zig build test` wedged forever in the never-answering-provider tests (4/4 runs on a64bd7e2, once for ~3h); the same one-shot abort guards every production deadline (`agent.request_timeout_ms`, `stream_idle_timeout_ms`), so an agent run racing a short deadline could park the same way.
- **Resolution:** Resolved on 2026-08-19. Abort.triggered latch + retrigger-until-done in chatWithTimeout and DeadlineWatch.watch, retries refused after a deliberate abort; verified by two consecutive green zig build test runs (1685/1696, 11 skipped) after a pristine-main control wedged on run 1

## Status

Resolved on 2026-08-19. Abort.triggered latch + retrigger-until-done in chatWithTimeout and DeadlineWatch.watch, retries refused after a deliberate abort; verified by two consecutive green zig build test runs (1685/1696, 11 skipped) after a pristine-main control wedged on run 1

## Symptom and impact

`zig build test` intermittently never returns: the test binary sits at ~0% CPU
in `llm.client.test.bounded chat aborts a provider that never sends a
response`, or its sibling `cli.test.a provider that never answers costs the
sweep its budget, not the OS connect timeout`. On a64bd7e2 the hang became
effectively deterministic (4/4 runs, one pristine). Beyond the suite, the same
code path guards every production LLM deadline, so the exposure is not
test-only: any `chatWithTimeout`/`chatWithDeadline`/`chatStreamWithTimeout`
caller whose deadline lapses inside the race window parks forever instead of
reporting `error.Timeout`.

## Reproduction

On ea246c5f (2026-08-19), a pristine detached worktree wedged on the first
run of `zig build test`. `sample <pid>` of the parked binary:

```
llm.client.test.bounded chat aborts a provider that never sends a response (client.zig:1575)
  llm.client.chatWithTimeout (client.zig:372)          <- future.cancel
    Io.Threaded.cancel -> Future.waitForCancelWithSignaling
      Thread.futexWaitUncancelable                     <- waits forever
```

The test's 30ms deadline loses the race against worker-thread startup under
suite load, which is why parallel test binaries made it near-deterministic.

## Root cause

Three cooperating defects in `src/llm/client.zig`, all downstream of the same
assumption — that one `Abort.trigger` at the deadline is enough:

1. **The trigger is one-shot and can land in a window where it does nothing.**
   `chatWithTimeout` fires `abort.trigger` exactly once when the deadline
   lapses. If the worker has not yet reached `arm()` (thread spawn plus
   request setup can outlast a short deadline), or has armed but its
   connection is not yet in the pool's `used` list, the trigger shuts down
   zero sockets. The worker then connects and parks in a read nothing will
   ever unblock.
2. **`future.cancel` cannot rescue a blocked read — by design.** As the
   `Abort` doc itself records, `Threaded.waitForCancelWithSignaling` only
   signals threads parked in cancelable syscalls; a blocking read on an
   established connection is not one, so the canceller futex-waits with no
   timeout and wedges alongside the worker. Calling it while the worker may
   still be in a read made it the only line of defence exactly where it is
   guaranteed to fail.
3. **A successful trigger could still re-park the request.** The shutdown
   surfaces in the worker as a retryable transport error; the retry loops in
   `chat`/`chatStream` then opened a fresh connection with no watchdog left
   alive (`DeadlineWatch.watch` triggers once and returns), re-creating the
   unrescuable read on the caller's own thread in the `underDeadline` shape.

## Resolution

- `Abort` latches `triggered` (set under the same mutex as the shutdown walk,
  including when nothing was armed), and `abortWasTriggered` is consulted by
  `retryAfterTransportError` and both HTTP-status retry branches: a call that
  was deliberately aborted never retries.
- `chatWithTimeout` no longer fires once and hopes: after the deadline lapses
  it retriggers on a `deadline_watch_tick_ms` (250ms) tick until the worker
  itself reports `done`, and only then reaps the future — `future.cancel` is
  never the only thing standing between a late-arming worker and a permanent
  park.
- `DeadlineWatch.watch` does the same after recording `fired`, instead of
  trigger-and-return.

## Verification

- Pre-fix control: pristine ea246c5f wedged on run 1 with the stack above.
- Post-fix: two consecutive full `zig build test --summary all` runs on the
  fix tree pass green (`322/322 steps succeeded; 1685/1696 tests passed
  (11 skipped)`), both never-answering-provider tests included, completing in
  normal time (~1m for the main binary).

## Follow-up

- The hang was intermittent for days and near-deterministic only recently;
  nothing here bisects *why* the window widened in 20fe5628..a64bd7e2 (more
  tests, more thread contention is consistent with the evidence but not
  proven). With the race class removed this is academic.

## References

- Investigation: [zig build test intermittently hangs forever in the bounded-chat abort test](../investigations/2026-08-18-bounded-chat-abort-test-hangs.md)
- `src/llm/client.zig` — `Abort`, `chatWithTimeout`, `DeadlineWatch`,
  `retryAfterTransportError`.
- Runbook context: recovery was kill-by-cwd and rerun
  (docs/reports/investigations/2026-08-18-bounded-chat-abort-test-hangs.md,
  Recovery section).
