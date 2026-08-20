# Bug — improve-self session_search capability eval failed with session:true not granted, stopping the batch

## TL;DR

- **What failed:** The SQLite session refactor gated ck_session on a new `session: true` descriptor flag. When it was absent, session_search hard-failed and its capability eval scored 0.00, rejecting every improve proposal and stopping the batch after iterations 1 and 2.
- **Impact:** improve-self stopped the batch after iterations 1 and 2 because every proposal failed the session_search capability eval.
- **Resolution:** Resolved on 2026-08-20. Fixed by 759a54c3 adding session: true to the session manifests; guarded by a toolDescriptorGate rule and a search-path host test, with build/tools/test green in the worktree.

## Status

Resolved on 2026-08-20. Fixed by 759a54c3 adding session: true to the session manifests; guarded by a toolDescriptorGate rule and a search-path host test, with build/tools/test green in the worktree.

## Symptom and impact

From the failing batch (worktree `1787254272063482177-main`, ts_ms 1787254...–1787257...), every proposal in iterations 1 and 2 was rejected by the same gate:

```
[WARN] request_id=improve capability evals: 1 case(s) failed; retrying only those
[ERROR] request_id=improve staged tree failed its own capability evals:
[ERROR] request_id=improve session_search: 0.00 FAIL
[WARN] [session] denied: tool descriptor does not set "session": true
[INFO] tool 'session_search' -> 187 bytes
[WARN] request_id=improve iteration 2: all attempts failed
```

Proposals touching unrelated files (`alarm.zig`, `bugreport.zig`, `rate_limit.zig`) all failed on this one eval, so the batch stopped after iterations 1 and 2 with nothing landed.

## Root cause

The SQLite session store refactor (`759a54c3`) moved the session tools behind a host `ck_session` seam and introduced a new opt-in descriptor gate: a tool may call `ck_session` only when its manifest sets `"session": true`. The gate trip is `Err.denied` (rc 1 → the guest's `error.SandboxDenied`). The session tools' guests (`tools/zig/sessions.zig`, `session_export.zig`) only degrade gracefully on `error.NoAccess` (rc 7), not on `error.SandboxDenied`, so a missing grant turned every `session_search` call into a hard `{"ok":false,...}` error (~187 bytes) instead of the documented `{"ok":true,"hits":[...]}` shape.

The `session_search` capability eval (`evals/session_search.task.json`) asserts `ok:true` with a `hits` array (or the typed min-length error); a hard grant error matches neither, so it scored 0.00. Because the improve capability gate runs the evals after the cheap build/tools/test gates and rejects any proposal whose staged tree fails them, a grant that was dropped for any reason failed every proposal and wasted the whole batch before it could be traced to the descriptor.

## Resolution

The three session manifests (`session_search.tool.json`, `sessions.tool.json`, `session_export.tool.json`) now set `"session": true`, added by the same `759a54c3` commit that introduced the gate, so `ck_session` is granted and the eval passes.

Two guards land with this report so the failure is caught cheaply and early instead of through the expensive LLM-backed evals:

- `toolDescriptorGate` (`src/gate/checks.zig`) now refuses any manifest whose `name` starts with `session_` that does not set `"session": true`. This runs in staging before the capability evals, so a future dropped grant rejects the proposal with a clear message instead of burning the whole batch.
- The host test `sessions and graph report empty when the state dir does not exist` (`src/sandbox/runtime.zig`) now also runs the search path (`{"q":"the"}`) with the grant present and asserts `ok:true` with a `hits` array — the exact assertion the capability eval makes — so a guest-side break is caught by `zig build test`.

## Verification

- `zig build`, `zig build tools`, `zig build test` all green in the worktree.
- The new `toolDescriptorGate requires session tools to grant session` test passes.
- All three session manifests carry `"session": true`.

## Follow-up

## References

- Investigation: none yet
