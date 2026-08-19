# Investigation — zig build test intermittently hangs forever in the bounded-chat abort test

## TL;DR

- **Question:** llm.client's 'bounded chat aborts a provider that never sends a response' (client.zig:1624) intermittently never returns: the test binary sits at ~0% CPU indefinitely. Seen twice in four otherwise-green runs of one tree on 2026-08-18 (arm64 macOS), once for 3 hours. Suspect: the 2026-08-17 request watchdog sometimes fails to unblock the parked read. Recovery: kill the test binary (match by cwd) and rerun.
- **Finding:** Investigating on 2026-08-18.
- **Resolution:** Resolved on 2026-08-19. root-caused to the one-shot Abort.trigger + uncancelable read; fixed in bugs/2026-08-19-bounded-chat-one-shot-abort-wedges.md (Abort.triggered latch, retrigger-until-done); two full green suite runs verify

## Status

Resolved on 2026-08-19. root-caused to the one-shot Abort.trigger + uncancelable read; fixed in bugs/2026-08-19-bounded-chat-one-shot-abort-wedges.md (Abort.triggered latch, retrigger-until-done); two full green suite runs verify

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Evidence

- 2026-08-18, run A: gate (zig build, zig build tools, zig build test) on 20fe5628 plus a webui-only diff. 'zig build test' stalled; the test binary showed 0.2% CPU after 30 minutes. 'sample <pid>' put the main thread in llm.client.test.bounded chat aborts a provider that never sends a response (client.zig:1624). Two other builds were running concurrently at the time.
- 2026-08-18, run B: same command on a64bd7e2 plus a webui-only diff, no concurrent builds. Same test, same frame, ~0.1% CPU, still parked after 2 h 58 m. This rules out build concurrency as the trigger.
- Two runs of the same tree(s) earlier the same day completed green (1623/1634 and 1625/1636, 11 skipped), so the hang is intermittent, roughly 2 in 4 today.
- Three orphaned test binaries from another session's worktree, ~4.4 days old, were found parked in the sibling test cli.test.a provider that never answers costs the sweep its budget, not the OS connect timeout (+1556), all at 0% CPU. So both never-answering-provider tests can wedge, and a wedged one never ages out on its own.
- The suite under test is the request watchdog shipped 2026-08-17 (agent.request_timeout_ms / stream_idle_timeout_ms; docs/reports/bugs/2026-08-17-agent-llm-call-has-no-deadline.md): the watchdog arms on a worker thread and Abort shutdown(2) is what unblocks the read. A hang here means that shutdown sometimes does not unblock the parked read, or the watchdog thread never fires.

## Recovery

- Identify the wedged binary by cwd, never by argv (the build runner's argv is relative): iterate pids from 'ps', match 'lsof -p <pid> -d cwd' against the worktree, confirm with 'sample <pid>' that the main thread is in one of the two never-answering-provider tests, then kill it and the parent 'zig build test'. A rerun of the same tree passes.
- Reproduction is not on demand: the same tree passed twice and hung twice on the same day. Nothing here bisects to a change in the tree under test; the diffs in both hanging runs were webui-only files the test never touches.
## Control run (2026-08-19)

A pristine detached worktree of a64bd7e2 (origin/main, no diff at all) wedged the same way: 'zig build test' parked in llm.client.test.bounded chat aborts a provider that never sends a response at ~0% CPU, confirmed by 'sample' after the 10-minute threshold. That makes the score on a64bd7e2 four hangs in four runs (three on a webui-only diff, one on pristine main), against three completed green runs earlier the same day on 15c9138c/20fe5628 bases. The hang therefore lives on current main independent of any working diff, and became much more frequent (possibly deterministic) somewhere in 20fe5628..a64bd7e2 — af6703e2 ('toolhost registry, cli updates') and 317c257b/cecb96f8 are the commits in that window. Not bisected further; recovery remains kill-by-cwd and rerun, but on a64bd7e2 reruns no longer converge.

## Evidence — 2026-08-19 session, four more wedges, both offender tests sampled

Four wedges across five gate runs in one session, three of them consecutive
in one worktree while two sibling worktrees on the same base passed. Each
sampled at ~0% CPU with the stack pinned in the test:

- `cli.test.a provider that never answers costs the sweep its budget, not the OS connect timeout` (cli.zig:17179), sampled twice, 6+ and 9+ minutes in.
- `llm.client.test.bounded chat aborts a provider that never sends a response` (client.zig:1575), sampled once, unchanged across two samples 90s apart.

Kill-and-rerun converged on the fifth attempt (320/320, 0 failed). The
consecutive wedges in one directory and none in its siblings look like a
streak, not a property of the directory: the fifth run in that same
directory passed with no change to the tree.
## Root cause found (2026-08-19)

Reproduced on pristine ea246c5f: first run wedged, and 'sample' pinned the main thread at client.zig:372 — future.cancel inside Threaded.waitForCancelWithSignaling, futex-waiting forever. Mechanism: chatWithTimeout fires Abort.trigger exactly once at the deadline; a trigger landing before the worker armed the abort (or before its connection reached the pool) shuts down nothing, the worker then parks in a read, and cancel cannot rescue a blocked read. The retry loops added a second wedge shape: a successful trigger surfaces as a retryable transport error and the retry re-opens a connection with no watchdog left. Confirmed defect filed as docs/reports/bugs/2026-08-19-bounded-chat-one-shot-abort-wedges.md, which carries the fix (latched Abort.triggered + retrigger-until-done) and verification.