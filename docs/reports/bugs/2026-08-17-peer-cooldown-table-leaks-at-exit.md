# Bug — Peer cooldown table is never freed, so any command that reaches a down peer ends in a leak trace

## TL;DR

- **What failed:** fanOut -> recordFailure grows a process-global peer_cooldowns list that only the test-only resetCooldowns frees, so a Debug build prints a DebugAllocator leak trace at exit whenever a configured peer is unreachable.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-17. Fixed: the cooldown table is a fixed-size process-lifetime array that copies the peer name (src/peers/chatrooms.zig), so nothing is allocated to leak and nothing borrows the request arena.

## Status

Resolved on 2026-08-17. Fixed: the cooldown table is a fixed-size process-lifetime array that copies the peer name (src/peers/chatrooms.zig), so nothing is allocated to leak and nothing borrows the request arena.

## Symptom and impact

## Reproduction

Observed on 2026-08-17 while running `clanker janitor --yes` on a Debug build
of this checkout, with a `[[peers]]` entry named `dummy-down` that does not
answer. The command succeeded and then printed:

    [ERROR] chat to 'dummy-down' failed: the request did not complete; marking peer down, backing off 5s
    [ERROR] (DebugAllocator) memory address 0x7f33f4da5200 leaked:
      .../array_list.zig ... in append
      src/peers/chatrooms.zig:748:16: in recordFailure
      src/peers/chatrooms.zig:883:43: in fanOut

Any command whose fan-out reaches an unreachable configured peer should do it;
the janitor run is incidental.

## Root cause

`peer_cooldowns` (`src/peers/chatrooms.zig:718`) is a process-global
`?std.ArrayList(PeerCooldown)`. `recordFailure` allocates it on first use
(`chatrooms.zig:740`) and appends one entry per failing peer
(`chatrooms.zig:748`). The only code that frees it is `resetCooldowns`
(`chatrooms.zig:770-774`), whose own doc comment marks it test-only and whose
only callers are the test at `chatrooms.zig:1445-1446`.

There is no process shutdown hook to free it from: `grep` for `deinit()`,
`shutdown` or `atexit` in `src/main.zig` returns nothing.

The table is bounded — one entry per configured peer, and `name` is stored by
reference rather than duped — so this is a fixed-size allocation held for the
process lifetime, not unbounded growth. What is wrong is that it is held in an
allocator that audits at exit, so a normal command ends in a leak trace.

Unverified: whether the borrowed `name` slice outlives every path that reads
it. The entries come from `fanOut`'s `r.name`; this was not traced.

## Resolution

Open. Two shapes, neither attempted here:

1. Free the table at process teardown. Needs a shutdown hook that does not yet
   exist, which is why this is a report rather than a patch.
2. Allocate the table from an allocator that is not leak-audited, which says
   "process-lifetime by design" in the code instead of in a comment.

## Verification

None yet — nothing was changed.

## Follow-up

Same operator-visible class as
[the resolveExecPath candidate leak](2026-08-17-resolveexecpath-candidate-leak.md),
which was fixed rather than accepted, so the precedent is to fix it.

## References

- Investigation: none yet
