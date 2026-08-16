# Bug — resolveExecPath leaks PATH-candidate allocations through ckStdApi

## TL;DR

- **What failed:** Every clanker run on this checkout ends with DebugAllocator leak traces pointing at src/sandbox/host.zig:3621: resolveExecPath's std.fmt.allocPrint candidate strings reached via ckStdApi's rg resolution (host.zig:3746) are reported leaked at process exit. Observed twice on 2026-08-16/17 in run shutdown logs; repeated once per ck_std_api rg lookup. Traced: the returned path is never freed by ckStdApi; the loop frees non-matching candidates correctly.
- **Impact:** Bounded leak-trace noise at shutdown (one small allocation per ck_std_api lookup); no state corruption.
- **Resolution:** Resolved on 2026-08-16. Fixed by adding defer h.sandbox.gpa.free(rg) in ckStdApi (src/sandbox/host.zig:3747), matching the other three resolveExecPath callers; checked by code audit of all four call sites and a gate run whose only test failure is a concurrent session's in-flight graph_listing change.

## Status

Resolved on 2026-08-16. Fixed by adding defer h.sandbox.gpa.free(rg) in ckStdApi (src/sandbox/host.zig:3747), matching the other three resolveExecPath callers; checked by code audit of all four call sites and a gate run whose only test failure is a concurrent session's in-flight graph_listing change.

## Symptom and impact

DebugAllocator leak traces at process exit, one per `ck_std_api` symbol lookup, each pointing at the `std.fmt.allocPrint` in `resolveExecPath` (src/sandbox/host.zig:3621) reached from `ckStdApi` (src/sandbox/host.zig:3746). The leak is bounded (one PATH-resolved `rg` path per lookup, tens of bytes each) and does not corrupt state; the impact is leak-trace noise at shutdown that buries real leaks, plus slow growth on long runs that use the `zig_std` tool repeatedly.

## Reproduction

Run any task that makes the `zig_std` tool query the standard library (each query calls `ckStdApi`, which PATH-resolves `rg`), on a debug build, and read the run shutdown log: DebugAllocator prints a leak trace whose allocation stack ends at host.zig:3621 via host.zig:3746.

## Root cause

`resolveExecPath` returns a caller-owned allocation: non-matching PATH candidates are freed inside its loop (host.zig:3623), and the matching candidate is returned for the caller to free. Three of its four callers pair the call with `defer gpa.free` (`ckExec` at host.zig:4506-4507, `execUnderPolicy` at 4682-4683, `execUnderPolicyInput` at 4766-4767). `ckStdApi` was the fourth: it bound the result to `rg`, used it in the argv, and returned without freeing it on any path — so the report's open question resolves to "the returned path, never freed by ckStdApi", not the loop candidates.

## Resolution

`ckStdApi` now frees the resolved path on every return path: `defer h.sandbox.gpa.free(rg);` immediately after the `resolveExecPath` call (src/sandbox/host.zig:3747). This matches the ownership contract the other three callers already follow. CHANGELOG entry added under Unreleased/Fixed.

## Verification

- Code audit: all four `resolveExecPath` call sites now pair the returned allocation with a `defer free`; the loop inside `resolveExecPath` already freed non-matching candidates.
- `clanker gate` after the fix: build PASS; `zig build test` 1457/1463 pass, 5 skip, 1 fail — the one failure is `graph_listing.decltest.lessThanChronological` in `tools/zig/graph_listing.zig`, a concurrent session's in-flight change (claimed on the local board, investigation 2026-08-17-web-ui-run-history-stale.md), unrelated to this fix. Every sandbox/host test passed.
- Not re-verified at runtime: a debug-build run exercising `zig_std` after the fix (needs a live provider); the fix is deterministic — the defer covers the early-return (`allocPrint` failure) and normal paths both.

## Follow-up

None.

## References

- Investigation: none yet
