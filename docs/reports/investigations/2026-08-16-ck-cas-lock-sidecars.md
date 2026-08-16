# Investigation — ck_cas lock sidecars are never removed and bypass the create retry

## TL;DR

- **Question:** Never unlinking a held advisory lock is correct, so the accumulating *.ck_cas.lock files are not a cleanup bug; but fs_write_if creates its lock with base.createFile instead of file_lock.createFileRetry, violating the invariant its own module doc states, and it creates the sidecar before the hash compare so a mismatch litters a doc that was never written.
- **Finding:** Not a cleanup bug. A held advisory lock lives on the inode, so unlinking the sidecar would break mutual exclusion, and `file_lock.zig` never removes its lock files either. Two other defects surfaced: `fsWriteIfImpl` takes its lock with raw `base.createFile` instead of `file_lock.createFileRetry`, and it creates the sidecar and parent dirs before the hash compare, so a mismatch litters a target that was never written.
- **Resolution:** No cleanup fix wanted. Route host.zig:3208 through `createFileRetry`.

## Status

Closed on 2026-08-16. Traced to no cleanup defect: never unlinking a held advisory lock is the correct pattern and matches file_lock.zig. Two unrelated defects recorded in the Finding section.

## Trigger and scope

35 zero-byte `*.ck_cas.lock` files were found across the checkout (34 in the
repo, 20 of those copied into `.clanker-worktrees/*`, plus one under
`clanker-state/recovery/`). None is tracked; `.gitignore:67` already carries
`*.ck_cas.lock`. The question raised was whether a cleanup path is missing.

Scope is `fsWriteIfImpl` in `src/sandbox/host.zig` (the `ck_fs_write_if`
compare-and-swap host function) and the shared helper `src/util/file_lock.zig`.

## Evidence

`fsWriteIfImpl` (src/sandbox/host.zig:3189-3236) performs, in order:

1. `createDirPath` for the parent directory (3199-3202)
2. create `<target>.ck_cas.lock` with `.lock = .exclusive`, hold the handle
   (3208-3211)
3. read current contents (3214)
4. SHA-256 and compare against `expected_hex` (3224-3231)
5. `base.writeFile` only on match (3234); `return Err.mismatch` otherwise (3230)

The only operations on `lock_path` are the create and `defer
lock_file.close(sb.io)`. There is no `unlink` of that name anywhere in the
tree.

`src/util/file_lock.zig` behaves the same way: `acquire` creates
`{dir}/{name}.lock` (file_lock.zig:56) and `Guard.release` only closes it
(file_lock.zig:22-25). No lock file in this codebase is ever removed.

## Hypotheses and tests

## Finding

**The accumulation is not a bug.** The advisory lock lives on the open inode,
not on the path. Unlinking the sidecar while holding it would break mutual
exclusion: a process that already opened the old inode keeps "holding" a lock
on a now-unreachable inode while a third process creates a fresh file at the
same path and locks that one, leaving two writers both believing they hold the
lock. A permanent empty sidecar is what guarantees one path always resolves to
one lock inode. Closing the handle releases the lock, so the leftover file is
inert. `file_lock.zig` is deliberately identical, so the behaviour is the
established project pattern rather than an oversight.

Two real defects surfaced while confirming that.

**1. `fsWriteIfImpl` bypasses `createFileRetry`.** `appendLocked`
(host.zig:3135) takes its lock through `file_lock.createFileRetry`, with a
comment naming the hazard. `fsWriteIfImpl` (host.zig:3208) calls raw
`base.createFile` instead. That contradicts the invariant `file_lock.zig:37-39`
states: *every* create of a shared file that must not silently drop work, the
lock file itself included, goes through the retry. Consequence: two guests
racing `fs_write_if` on a target whose lock file does not exist yet can hit the
spurious `ENOENT` documented at file_lock.zig:28-35 (~2 in 400 racing creates on
macOS/APFS), and the `catch` at host.zig:3209 turns a valid CAS write into
`Err.invalid`. Blast radius is smaller than `appendLocked`'s: the guest sees an
explicit failure rather than a silently dropped record, so this is a loud-but-
wrong error, not corruption. Essentially unreachable on Linux.

**2. The sidecar and the parent directory are created before the compare.** A
CAS that returns `Err.mismatch` — the ordinary contention outcome — has already
created the lock file next to a target it never wrote, and `createDirPath` at
step 1 can materialise a parent directory tree for that same never-written
target. This is why sidecars appear beside documents that no write ever
touched.

## Resolution or handoff

No cleanup fix is warranted; deleting sidecars is safe housekeeping but they
return on the next CAS write, and code that unlinks them while a lock is held
would be a regression.

Open for defect 1: route host.zig:3208 through `file_lock.createFileRetry` so
the lock create honours the invariant its own helper documents.

Optional for defect 2: keeping sidecars out of the source tree entirely would
mean locking on a path-derived name under `state/` rather than beside the
target. That is a design change, not a fix, and it is not required for
correctness.

## References

- Related bug: none yet
