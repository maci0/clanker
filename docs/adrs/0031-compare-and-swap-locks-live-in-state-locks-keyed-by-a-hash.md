# ADR 0031 — Compare-and-swap locks live in state/locks, keyed by a hash of the target path

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0006 — Where ck_cas lock sidecars live](../rfcs/0006-where-ck-cas-lock-sidecars-live.md).

## Context

Every ck_fs_write_if compare-and-swap takes an advisory flock on a lock file, and a lock file is never unlinked: unlinking one while it is held moves the lock onto an unreachable inode, so a second process can create a fresh file at the same name and lock that one, leaving two writers both believing they hold it. The lock file is therefore permanent by design. Naming it <target>.ck_cas.lock put a permanent zero-byte file beside every document ever CAS-written: 46 in this checkout on 2026-08-17, 20 of them copied into .clanker-worktrees, one per record in docs/reports, docs/rfcs, docs/adrs, docs/prds and docs/runbooks. They are gitignored (.gitignore:71) and inert, so this is a placement question and not a correctness one, but it is the one an operator reads as leftover garbage. RFC 0006 raised it on 2026-08-16 and left it open because the deciding fact was whether anyone minded the sidecars in practice; on 2026-08-17 the operator reported them as litter that was not being cleaned up.

## Decision

fsWriteIfImpl builds its lock path as {state_dir}/locks/<sha256-hex-of-resolved-target-path>.lock instead of <target>.ck_cas.lock. The directory is created with util.ensureDir, not createDirPath, because an isolated run's state is a symlink to the checkout's. The hash is over the resolved path, so distinct targets still serialise independently and two checkouts sharing one state directory do not collide; state is in shared_prefixes, so a worktree run reaches the checkout's lock directory through its state symlink and maps a given target to the same lock inode the checkout does. The lock file also carries a fixed-width holder record (pid, acquired_ms, tool, target) rendered by tools/zig/cas_lock_record.zig, shared with the janitor guest that reads it back. The target's parent directories are now created after the hash compare rather than before it, so an ordinary mismatch no longer materialises a directory tree for a file it never wrote.

> The RFC recommended: **Recommended option:** Option A — move the sidecar to state/locks/ keyed by a hash of the target path


## Consequences

The lock is no longer visibly adjacent to what it guards, so a stuck lock is one hash lookup further away — the holder record is what pays that back, naming the run and the moment instead of being a zero-byte name. state/locks accumulates one file per distinct target path ever CAS-written; that plateaus for repo documents but grows without bound for ephemeral targets such as a test's tmp tree or an improve staging copy, so clanker janitor now sweeps lock files whose recorded acquisition is more than 12 hours old. The record is diagnostics only and must never gate a lock: an flock is released by the kernel when the holding descriptor closes, crash included, so no holder has to prove liveness and a heartbeat would guard a failure mode that cannot occur. The host now writes into state/ on behalf of guests whose fs_prefixes do not include it, which is host bookkeeping in the same class as token_stats, not guest authority. Existing <target>.ck_cas.lock sidecars are dead once nothing creates them and were removed once, by hand.
