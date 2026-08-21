# Bug — SQLITE_TRANSIENT translate-c cast breaks the build on aarch64-macos

## TL;DR

- **What failed:** The session-store sqlite binding passed `c.SQLITE_TRANSIENT` to `sqlite3_bind_text`; translate-c materializes `(sqlite3_destructor_type)-1` as a comptime `@ptrFromInt` of all-ones, which zig rejects on targets whose function pointers require alignment (aarch64-macos), so `zig build` failed on untouched files for every branch cut from main.
- **Impact:** main did not compile on aarch64-macos from 759a54c3 (the commit that introduced `src/util/sqlite.zig`) until this fix; every local gate on this platform was red before any diff under test even entered the picture.
- **Resolution:** Resolved on 2026-08-21. bindText goes through an @extern sqlite3_bind_text with a usize destructor param; gate green on aarch64-macos (333/333 steps, 1808 passed)

## Status

Resolved on 2026-08-21. bindText goes through an @extern sqlite3_bind_text with a usize destructor param; gate green on aarch64-macos (333/333 steps, 1808 passed)

## Symptom and impact

`zig build` (Debug, native aarch64-macos) fails in `lib/std/zig/c_translation/helpers.zig:234` with `error: pointer type '?*const fn (?*anyopaque) callconv(.c) void' requires aligned address`, referenced from `cimport.zig`'s `SQLITE_TRANSIENT` via `src/util/sqlite.zig:113` (`bindText`) and its callers in `src/agent/session.zig`. The failure is in files a branch under test never touched, so it reads as "your diff broke the build" while the base itself is red.

## Reproduction

Check out any commit from 759a54c3 up to (not including) the fix on an aarch64-macos host and run `zig build`. On targets whose function pointers have alignment 1 the cast is accepted, which is why the break shipped.

## Root cause

sqlite defines `SQLITE_TRANSIENT` as `((sqlite3_destructor_type)-1)` — a sentinel the library compares by value and never calls. translate-c turns that into a comptime cast of `usize`-all-ones to a zig function pointer type. Function pointers on aarch64-macos carry an alignment requirement, and comptime `@ptrFromInt` enforces it, so the constant itself is a compile error the moment anything references it.

## Resolution

`src/util/sqlite.zig` redeclares the one function that takes the sentinel via `@extern` with the destructor parameter typed as `usize` (`sqlite3_bind_text_raw`), and passes `std.math.maxInt(usize)` for SQLITE_TRANSIENT. ABI-identical, no C shim, no build.zig change; `c.SQLITE_TRANSIENT` is no longer referenced anywhere.

## Verification

Full local gate on aarch64-macos at the fix commit: `zig build`, `zig build tools`, `zig build test --summary all` → `Build Summary: 333/333 steps succeeded; 1808/1819 tests passed (11 skipped)`. The session-store tests (`src/agent/session_events.zig`) exercise `bindText` against a real database, so the transient copy semantics are covered, not just the compile.

## Follow-up

- If another bind ever needs SQLITE_TRANSIENT (blob binds, say), route it through the same `@extern` pattern rather than reintroducing `c.SQLITE_TRANSIENT`.

## References

- Investigation: none — root cause was evident from the compile error.
- Introduced by 759a54c3 (session tools: read the SQLite session store through a host ck_session seam).
