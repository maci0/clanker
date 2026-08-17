# Bug — improve-self stalls re-asking for a granted file too large to include

## TL;DR

- **What failed:** improve-self batches stopped after two adjacent iterations each logged "all attempts failed", preceded by "file request added nothing new". The model re-requested a file the "NOT INCLUDED" list told it to ask for, but which exceeds the granted-file quota and is omitted again. grant() called an already-granted-but-omitted file "already in the context above", so the model re-asked until the retry budget died.
- **Impact:** The autorecover loop kills the batch after two adjacent failed iterations, so the instruction that triggered the loop (here "improve improve-self") never lands an improvement.
- **Resolution:** Resolved on 2026-08-17. grant() now reports a re-request for an omitted granted file as "too large to include" instead of "already in the context above"; verified by the new unit test and a green clanker gate.

## Status

Resolved on 2026-08-17. grant() now reports a re-request for an omitted granted file as "too large to include" instead of "already in the context above"; verified by the new unit test and a green clanker gate.

## Symptom and impact

From a failed improve-self batch (ts_ms=1786990623023):

```
[WARN] request_id=improve file request added nothing new; asking for a patch instead  (repeated 2 times)
[WARN] request_id=improve iteration 1: all attempts failed
[WARN] request_id=improve file request added nothing new; asking for a patch instead  (repeated 2 times)
[WARN] request_id=improve iteration 2: all attempts failed
```

The autorecover loop (`scripts/imp-autorecover-loop/loop.py`) treats two adjacent `all attempts failed` iterations as exhausted retries and kills the batch, so no improvement lands.

## Reproduction

Run `clanker improve-self "improve improve-self"` with a model whose context budget keeps `src/improve/engine.zig` (231,721 bytes) over the granted-file quota. The file is keyword-matched, omitted from the bulk as too large, listed under NOT INCLUDED, requested, granted, omitted again (over the `max_bytes/2` granted-file quota), then re-requested; `grant()` reports it as already-in-context and the iteration ends with all attempts failed.

## Root cause

`collectContext` drops any file that does not fit its block, and names the dropped file under NOT INCLUDED with "ask for one with need". A granted file sits in the request band whose quota is `max_bytes/2`, so `src/improve/engine.zig` (226 KB > 128 KB at a 256 KB budget) is dropped even after being granted.

`grant()` only distinguished "already granted" from "not yet granted". A re-request for an already-granted file returned `added == 0` and the feedback "Everything else you asked for is already in the context above" — false, because the file had been omitted and the model never saw it. The model was stuck between "ask for it" (NOT INCLUDED) and "you already have it" (grant), re-asking until `max_attempts_per_iter` (2) exhausted.

## Resolution

`Engine.omitted_granted` now records the granted files `collectContext` could not fit. `grant()` takes a `too_large` out-list and puts a re-request for one of those there instead of silently absorbing it. The "file request added nothing new" feedback names the too-large files and tells the model to propose with what is shown or answer no-changes, so the iteration ends cleanly instead of burning the retry budget.

## Verification

- New unit test `grant distinguishes an already-shown file from one granted but too large to show`.
- `clanker gate` (build, tools, test) green.

## Follow-up

## References

- Investigation: none yet
