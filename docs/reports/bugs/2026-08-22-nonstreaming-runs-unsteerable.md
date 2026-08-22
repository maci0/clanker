# Bug — Non-streaming runs never register a steer slot

## TL;DR

- **What failed:** Only the streaming POST /api/run path calls runRegister (src/cli.zig ~15515), so a run started with stream:false never claims a steer slot: every POST /api/steer against it answers 404 no_run and the run proceeds unsteerable with no indication to the caller. Same applies when all 64 steer slots are taken: runRegister returns false and the run silently starts without a steer_fn. Found while adding webui steering visibility on 2026-08-22.
- **Impact:** Every non-streaming run is unsteerable and the caller is never told. `POST /api/steer` answers 404 `no_run` for a run that is very much alive, which reads as "the run finished" rather than "this run never claimed a slot". The slot-table-full case is worse: it is load-dependent, so the same request is steerable or not depending on what else is running.
- **Resolution:** Resolved on 2026-08-22. Both branches of POST /api/run now register a steer slot, and runRegister returns a SteerRegister enum (ok, unkeyed, key_too_long, table_full) instead of a bool so an unsteerable run can be explained. Covered by tests/e2e/steer_nonstreaming_test.zig, which holds the mock answer open so the steer lands while the run is alive. clanker gate passes 11/11.

## Status

Resolved on 2026-08-22. Both branches of POST /api/run now register a steer slot, and runRegister returns a SteerRegister enum (ok, unkeyed, key_too_long, table_full) instead of a bool so an unsteerable run can be explained. Covered by tests/e2e/steer_nonstreaming_test.zig, which holds the mock answer open so the steer lands while the run is alive. clanker gate passes 11/11.

## Symptom and impact

A run started with `stream:false` on `POST /api/run` accepts no steering for
its whole life. `POST /api/steer` naming it answers 404 `no_run`, which is the
same answer a finished run gives, so a caller cannot tell "already over" from
"never steerable". The run itself is unaffected and completes normally.

The same silence covers two further cases that are not the same problem: all
64 slots taken (load-dependent, so the identical request is steerable or not
depending on what else is running), and a key longer than the caps (a caller
bug). All three arrived as one `false`.

## Reproduction

Start a non-streaming run and steer it:

```bash
curl -sS -X POST localhost:8080/api/run -H "content-type: application/json" -d "{\"task\":\"count slowly to twenty\",\"session\":\"probe\",\"stream\":false}" &
curl -sS -X POST localhost:8080/api/steer -H "content-type: application/json" -d "{\"session\":\"probe\",\"message\":\"stop\"}"
```

The second call answers 404 `no_run` while the first is still running. With
`"stream":true` the same pair works.

Covered from now on by `tests/e2e/steer_nonstreaming_test.zig`, which holds the
mock provider mid-answer so the steer lands while the run is provably alive.

## Root cause

`runRegister` was called only on the streaming branch of `POST /api/run` in
`src/cli.zig`. The non-streaming branch built its agent and ran it without ever
claiming a slot, so `steerKeysMatch` had nothing to match and every steer fell
through to the 404.

`runRegister` also returned a bare `bool`. Three unrelated outcomes — no key to
register under, every slot taken, key over the cap — all came back `false`, so
even the streaming path could not say why a run was unsteerable.

## Resolution

Both branches of `POST /api/run` now register, and `runRegister` returns a
`SteerRegister` enum (`ok`, `unkeyed`, `key_too_long`, `table_full`) instead of
a `bool`, so an unsteerable run can be explained rather than merely observed.
None of the non-`ok` answers stops the run: an unkeyed one-shot has nothing to
address it by and is the ordinary case, not a failure.

## Verification

`clanker gate` passes 11/11 with the change. `tests/e2e/steer_nonstreaming_test.zig`
drives the real HTTP surface: it spawns `clanker serve`, posts a non-streaming
run whose mock provider answer is held open, steers it by session id while the
run thread is provably still in the turn, then releases the answer and joins.

Unrelated and pre-existing: `zig build e2e` also fails
`pty_resize_test` and `pty_preview_test` in this worktree. Both pass in the
main checkout and both fail in a **pristine** worktree at the same commit, so
they are not caused by this change — see the linked investigation.

## Follow-up

## References

- Investigation: none yet
