# Bug — A CAS lock name hashes the path string, so one target can have two locks

## TL;DR

- **What failed:** fsWriteIfImpl names its lock file for the SHA-256 of the joined path string, not a resolved path. state/goals.json is './state/goals.json' in an unisolated run and '/abs/checkout/state/goals.json' in an isolated one (shared_root is currentPathAlloc), so the two runs take two different lock inodes on the same file and neither excludes the other. The sidecar the change replaced could not split that way: both spellings named one file on disk.
- **Impact:** Not observed on disk yet — no isolated run has CAS-written a shared path since the change landed. When it is reached, two writers to one shared file (`state/goals.json` is the reachable case) both pass the hash compare and both write, so the earlier write is lost.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

No symptom has been observed on disk yet: `state/locks/` holds 378 lock
files on 2026-08-17 and none has an absolute `target=`, so no isolated run
has taken a compare-and-swap lock on a shared path since the change landed.
The defect is read out of the code, and the two lock names it produces for
one file are shown below.

Impact when it is reached: `ck_fs_write_if` on a `shared_prefixes` path
(`state/`, `.local/`, `.agents/`, `.claude/`, `config.local.toml`) stops
excluding an isolated run from the checkout. Both writers pass the hash
compare against the same bytes and both write, so the later write wins and
the earlier one is lost — the exact outcome the compare-and-swap exists to
refuse. `state/goals.json` is the reachable case: `goal_update` CAS-writes
it and a `--worktree` run shares it with the checkout by design.

## Reproduction

The lock name is the SHA-256 of the joined path, so the two spellings can be
computed without running anything:

```bash
printf %s ./state/goals.json | sha256sum
```

```bash
printf %s /home/yannick/code/maci0/clanker/state/goals.json | sha256sum
```

They are `6b849a5a...786c37` and `a8ad66a0...25d27f`. Only the first exists
in `state/locks/`, and its record names the target it was taken for:

```bash
ls state/locks/6b849a5a00bfa97e42be0b359ec32bde403a90c26ae28ac97bf6536729786c37.lock
```

```bash
tr -s " " < state/locks/6b849a5a00bfa97e42be0b359ec32bde403a90c26ae28ac97bf6536729786c37.lock
```

That prints `pid=2126138 acquired_ms=1786972046880 tool=goal_update
target=./state/goals.json`.

## Root cause

`casLockPath` hashes `full` as it was handed to it
(`src/sandbox/host.zig:3401-3404`), and `full` is a string built by
`safeJoin` as `{rootForPath(sb, sub_path)}/{sub_path}`
(`src/sandbox/host.zig:5246`). Nothing resolves it.

`rootForPath` returns `sb.shared_root` for a path under `shared_prefixes`
and `sb.root_dir` otherwise (`src/sandbox/host.zig:5113-5134`). Those two
fields are spelled differently for the same directory:

- `root_dir` comes from `agent.sandbox_root`, whose default is `"."`
  (`src/sandbox/host.zig:335`), so the join is `./state/goals.json`.
- `shared_root` is set only for an isolated run, from
  `std.process.currentPathAlloc` (`src/cli.zig:3787`, assigned at
  `src/cli.zig:3827`), so it is absolute and the join is
  `/home/yannick/code/maci0/clanker/state/goals.json`.

A third spelling exists for any tool holding an absolute `fs_prefixes`
entry: `safeJoinAbsolute` returns the guest path verbatim
(`src/sandbox/host.zig:5274`).

The sidecar this replaced could not split, because `<target>.ck_cas.lock`
under either spelling named one file on disk and the kernel resolved them
to one inode. Keying on the string moved the identity of a lock from the
filesystem to whichever text the caller happened to use.

ADR 0031 states the opposite property in two places — "The hash is over the
resolved path" and "two checkouts sharing one state directory do not
collide". As implemented, one target can hold two locks (above) and two
checkouts sharing one `state/` collide, since both spell it `./docs/x.md`.
The collision direction only over-serialises and is harmless.

## Resolution

Open. Not attempted here; the check that found it was a review, not a fix.

The shape a fix needs is a name derived from the file rather than from the
text naming it: resolve the parent directory (`realPath` on the parent, not
on the target, which need not exist yet) and hash `{resolved_parent}/{basename}`.
That makes the three spellings above collapse to one lock again and makes
ADR 0031 true as written. Nothing already written is invalidated: an old
lock file simply stops being re-acquired and ages out of `state/locks/`
through the janitor sweep.

## Verification

None yet — there is no test over the lock name. The one that would fail
today: build two sandboxes over the same directory, one with `root_dir = "."`
and one with an absolute `shared_root`, CAS-write the same shared path
through each, and assert both land on one file in `state/locks/`.

Everything else about the change verified green on 2026-08-17:
`clanker gate` passes all eight gates, `src/sandbox/host.zig:6992` asserts
the lock lives under `state/locks/` with no sidecar beside the target and no
directory tree left behind by a mismatch, and `src/sandbox/host.zig:6906`
races eight threads at a not-yet-existing lock name and asserts none is
refused.

## Follow-up

Two smaller observations from the same review, neither a defect in the
decision:

1. The lock *directory* is resolved against the process cwd
   (`casLockPath` passes `base`, which `ckFsWriteIf` sets to
   `std.Io.Dir.cwd()`, `src/sandbox/host.zig:3289`) while the *target* is
   resolved against the sandbox root. A test whose sandbox root is a tmp
   tree therefore writes its lock into the real checkout `state/locks/`:
   most of the 378 files there carry `target=.zig-cache/tmp/<x>/docs/...`.
   The janitor ages them out at 12h, so this is retention rather than a
   leak, but a `zig build test` run leaves permanent files in an operator
   state directory.

2. `collectAgedLocks` (`tools/zig/janitor.zig:261`) has no test — the
   guest has no `test` block at all — and it reads every lock file whole
   into the 1 MiB guest arena. Every failure path is `catch continue` or
   `catch return`, so once the directory is large enough the sweep
   silently stops short exactly when it is needed. The parser it depends
   on is covered (`tools/zig/cas_lock_record.zig`), including the
   unreadable-record case that keeps a garbage record from dating to 1970
   and sweeping live locks.

## References

- Decision: [ADR 0031 — Compare-and-swap locks live in state/locks, keyed by a hash of the target path](../../adrs/0031-compare-and-swap-locks-live-in-state-locks-keyed-by-a-hash.md)
- Investigation: [ck_cas lock sidecars are never removed and bypass the create retry](../investigations/2026-08-16-ck-cas-lock-sidecars.md)
- RFC: [0006 — Where ck_cas lock sidecars live](../../rfcs/0006-where-ck-cas-lock-sidecars-live.md)
