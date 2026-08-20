# Bug — improve-self left src/acp/server.zig non-compiling across two commits

## TL;DR

- **What failed:** Two improve-self commits broke `zig build`: d8cbf2da/cb2c95e0 ("Hoist stdout File handle...") deleted the `stdout_file`/`out_buf` declarations in `serve()` without re-adding them, and ce3af5c1/faa57166 ("Store the validated cwd...") changed the `sessions` map value type to `[]const u8` while leaving `handleSessionNew` calling `sessions.put(alloc, owned, {})` with a `void` value. Restored the declarations and made the map store an owned copy of cwd. Verified build/test/tools/fmt green.
- **Impact:** To be confirmed.
- **Resolution:** Reopened on 2026-08-20. Reopened: the operator's parallel fix merge (7e218e41) reintroduced the duplicates (sessions member, deinit loop, owned_cwd, stdout_file/out_buf), breaking zig build again.

## Status

Reopened on 2026-08-20. Reopened: the operator's parallel fix merge (7e218e41) reintroduced the duplicates (sessions member, deinit loop, owned_cwd, stdout_file/out_buf), breaking zig build again.

## Symptom and impact

`zig build` failed with two compile errors in `src/acp/server.zig`, so
`clanker improve-self` exited status 1 (its staging build and its own gate run
both fail). The ACP stdio server could not compile, blocking every command that
links `src/acp/`.

## Reproduction

From the broken checkout, `zig build` reports:

1. `src/acp/server.zig:310`: `var writer = stdout_file.writerStreaming(io, &out_buf);` — `stdout_file` and `out_buf` undeclared.
2. `src/acp/server.zig:128`: `try conn.sessions.put(alloc, owned, {});` — `sessions` value type is `[]const u8`, `{}` is `void`.

## Root cause

Two improve-self commits, each duplicated across the history:

- `d8cbf2da` / `cb2c95e0` "Hoist stdout File handle and output buffer out of
  the ACP serve loop": deleted `var stdout_file = std.Io.File.stdout();` and
  `var out_buf: [64 * 1024]u8 = undefined;` from inside the loop but never
  re-declared them, leaving the two identifiers dangling.
- `ce3af5c1` / `faa57166` "Store the validated cwd in ACP session state":
  changed `Connection.sessions` from `StringArrayHashMapUnmanaged(void)` to
  `StringArrayHashMapUnmanaged([]const u8)` and taught `deinit` to free the
  value, but left the `put` call passing `{}` (void) as the value.

## Resolution

- Restored the two declarations inside the `serve` loop (a clean revert of the
  hoist's deletion; the buffer is a stack array, so there was no allocation to
  hoist).
- Made `handleSessionNew` store the validated cwd: `const owned_cwd = try
  alloc.dupe(u8, cwd);` and `try conn.sessions.put(alloc, owned, owned_cwd);`,
  with `errdefer alloc.free(owned_cwd)` scoped to the put. The cwd slice points
  into the parse arena (freed when `handleLine` returns), so it must be owned by
  the gpa allocator the map frees in `deinit`.

## Verification

`zig build`, `zig build test`, `zig build tools`, and `zig fmt --check` all pass.

## Follow-up

- The improve loop merged these non-compiling changes onto `main`; confirm why
  the staging gate did not reject them before merge (stale build cache, or the
  duplicate-commit pattern visible in `git log --graph` where the same change
  appears under two hashes).
- The repo owner independently fixed the same two defects on `origin/main` in
  commit `b8e192c9` ("fix(acp): restore stdout handle/buffer hoist and store
  the session cwd"), so this checkout's fix is equivalent but landed on a
  diverged local `main` (26 commits ahead of the stale `origin/main` ref, 7
  behind the real remote). Reconcile with `git fetch` + merge/rebase from a
  terminal (fetch is denied inside the sandbox).

## References

- Investigation: none yet
## Reopened 2026-08-20: the parallel-fix merge reintroduced the break

The checkout's own `main` had already been reconciled to the owner's `b8e192c9`
fix, but a later commit `7e218e41` ("Fix ACP stdio server compile errors",
author `ywy50`) was a bad merge of the parallel fixes: it *added* the duplicate
lines back instead of removing them. `git show 7e218e41` is net-additive —
duplicate `const owned_cwd`, a second `errdefer` + second `sessions.put`, and a
second in-loop `stdout_file`/`out_buf` declaration. The duplicate `sessions`
struct member and duplicated `deinit` free loop were also present at `HEAD`,
leaving `zig build` broken on `main` again.

Root cause of "the staging gate did not reject it": this break did not come
from an improve-self staged patch at all — it was a human/operator parallel
merge committed straight to `main` (`7e218e41`), which is outside the improve
loop's staging gate. The improve loop cannot protect `main` from a direct
commit that does not compile; only a `clanker gate` on `main` catches it.

## Resolution (reopened)

Working tree fix verified and committed: remove the duplicate `sessions`
member, the duplicated `deinit` loop, the duplicate `owned_cwd` declaration and
errdefer/put, and declare `stdout_file`/`out_buf` once before the `serve` loop
(the correct hoist). `zig build`, `zig build tools`, `zig build test`, and
`zig fmt --check` all pass (`clanker gate`).
