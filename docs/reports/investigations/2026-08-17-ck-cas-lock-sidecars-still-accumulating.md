# Investigation — ck_cas.lock sidecars still accumulating in the source tree

## TL;DR

- **Question:** RFC 0006 was never decided, so nothing ever stopped the litter; deciding it as Option A moves the lock to state/locks/.
- **Finding:** Not a regression, and not the improve loop. ck_fs_write_if creates the sidecar, so any record write does; the 2026-08-16 investigation fixed a different defect (the lock create bypassing createFileRetry) and deferred the litter itself to RFC 0006, which was still undecided, so nothing ever stopped it. A crashed run cannot leave a stale lock — the kernel releases an flock when the holding descriptor closes — so no heartbeat or TTL is warranted for the lock. What does need a retention rule is the lock file: a target that never recurs leaves one nothing will reuse.
- **Resolution:** Resolved on 2026-08-17. Lock moved to state/locks/ per ADR 0031; janitor sweeps aged lock files; 46 legacy sidecars removed once. Verified by zig build test, zig build tools, and a live janitor report-then-delete of a planted aged lock.

## Status

Resolved on 2026-08-17. Lock moved to state/locks/ per ADR 0031; janitor sweeps aged lock files; 46 legacy sidecars removed once. Verified by zig build test, zig build tools, and a live janitor report-then-delete of a planted aged lock.

## Trigger and scope

The operator reported `*.ck_cas.lock` files as litter that "was already
investigated and fixed" but is "still not getting cleaned up automatically",
and assumed the improve-self loop was creating them.

46 were present in the checkout on 2026-08-17 (`find . -name '*.ck_cas.lock'
-not -path './.git/*' | wc -l`), against 35 recorded by the 2026-08-16
investigation. All 46 were zero bytes and none was tracked (`git ls-files
'*.ck_cas.lock'` is empty; `.gitignore:71` carries the pattern).

Scope is `fsWriteIfImpl` in `src/sandbox/host.zig`, the `janitor` guest,
and RFC 0006.

## Evidence

**Not the improve loop specifically.** The sidecar is created by
`ck_fs_write_if`, the sandbox compare-and-swap host function, which is what
the five record-store guests write through. Every sidecar found sat beside a
`docs/` record. The improve loop is a heavy writer of records, not the
mechanism.

**Not a regression, and the earlier fix was a different defect.** The
2026-08-16 investigation
([record](2026-08-16-ck-cas-lock-sidecars.md)) closed with "no cleanup fix is
warranted" — never unlinking a held advisory lock is correct — and fixed only
that `fsWriteIfImpl` took its lock with raw `base.createFile` instead of
`file_lock.createFileRetry`. Confirmed still fixed: `src/sandbox/host.zig`
takes the lock through `createFileRetry`. The litter itself was deferred to
[RFC 0006](../../rfcs/0006-where-ck-cas-lock-sidecars-live.md), which was still
in Discussion on 2026-08-17 and half-filled with template placeholders,
including two headings both labelled "Option B".

**Why nothing cleans them up.** The lock is an `flock`: `std.Io.Threaded`
selects `posix.system.flock` (Threaded.zig:4316) for a
`CreateFileOptions.lock` on this target. The lock lives on the open file
description, so unlinking the file while it is held would let a second process
create a fresh inode at the same name and lock that one.

## Hypotheses and tests

**"A crashed run leaves a stale lock that needs a heartbeat or a TTL."**
Refuted. The kernel releases an `flock` when the last descriptor on it closes,
including on `SIGKILL` and on process death by any signal, so a held lock is
never stale and no holder has to prove liveness. `src/util/run_lock.zig` is
the case that *does* need reclaiming, and shows the difference: it is a pid
file, and it reclaims one by probing the owner with signal 0 — a liveness
question, not a clock.

**"The lock set is bounded, so placement is the only issue."** Partly. The
name is a hash of the target path, so it is one file per distinct target ever
CAS-written, not one per run — rewriting a report 500 times reuses one lock.
But a target that never recurs leaves a lock nothing will reuse, which the live
check confirmed: after the move, `state/locks/` held records with
`target=.zig-cache/tmp/33IBtmSvL7wYm1OR/docs/rfcs/...`, a test tmp tree that
no later write will address.

## Finding

The accumulation was never fixed because it was never decided. RFC 0006
recommended moving the lock (Option A, confidence 6/10) and explicitly left the
call to the operator, naming the deciding fact as "if nobody minds the
sidecars in practice, the status quo wins on zero risk". That fact arrived on
2026-08-17.

Two further defects surfaced while confirming it:

1. `fsWriteIfImpl` ran `createDirPath` on the target's parent *before* the
   hash compare, because the sidecar had to live inside that directory. An
   `Err.mismatch` — the ordinary contention outcome — therefore left a
   directory tree behind for a file it never wrote.
2. A held lock was un-attributable. The file was zero bytes, so a write that
   hung named neither the run nor the moment.

## Resolution or handoff

Decided as Option A in
[ADR 0031](../../adrs/0031-compare-and-swap-locks-live-in-state-locks-keyed-by-a-hash.md);
RFC 0006 closed as decided and its placeholder sections filled in.

- `fsWriteIfImpl` locks on `{state_dir}/locks/<sha256-of-resolved-target>.lock`,
  created with `util.ensureDir` so an isolated run's symlinked `state`
  works.
- The target's parent directories are created after the compare, so a mismatch
  no longer materialises them.
- The lock file carries a fixed-width holder record — `pid`, `acquired_ms`,
  `tool`, `target` — rendered by `tools/zig/cas_lock_record.zig`, which is
  host-tested and shared with the guest that parses it.
- `clanker janitor` sweeps lock files whose recorded acquisition is over 12
  hours old. That is a retention window for the lock *file*, not a liveness
  timeout for the lock.
- The 46 existing sidecars were deleted once, by hand, which is what RFC 0006
  Option A specified. Nothing creates them now.

Verified: `zig build test` and `zig build tools` green; the new host test
fails against the old lock path (checked by restoring it), and so does the
pre-existing parent-directory test, which is the coupling that forced the
create-dirs-first ordering. Live check — `clanker janitor` reported and then
deleted a planted lock whose record was two days old, and left the fresh ones
alone.

## References

- Related bug: none yet
