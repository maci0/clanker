# Bug — origin/main did not compile: an if mixed the optional catch-null form with an error-union else clause

## TL;DR

- **What failed:** 6cddda0e reached origin/main with if (toolJson(...) catch null) |raw| { ... } else |_| {} in cmdGoal. The catch produces an optional, the else |_| clause demands an error union, so zig build failed with expected error union type, found ?[]const u8 at that if and no clanker binary could be built from main. Repaired by dropping the else clause in 395f912d.
- **Impact:** No clanker binary could be built from main for about 25 minutes; every session on the shared checkout inherited the failure at its next build.
- **Resolution:** Resolved on 2026-08-17. Fixed in 395f912d by dropping the else |_| clause in cmdGoal; zig build green at that commit here and in the authoring session's checkout. Second occurrence of the class in 2026-08-16-pushed-main-did-not-compile.md.

## Status

Resolved on 2026-08-17. Fixed in 395f912d by dropping the else |_| clause in cmdGoal; zig build green at that commit here and in the authoring session's checkout. Second occurrence of the class in 2026-08-16-pushed-main-did-not-compile.md.

## Symptom and impact

`zig build` fails for everyone on the checkout, in a file and a function
unrelated to whatever the building session is working on:

```
src/cli.zig:5716:88: error: expected error union type, found '?[]const u8'
            if (toolJson(io, init.gpa, arena, &cfg, init.environ_map, "goal_add", inp) catch null) |raw| {
                ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^~~~~~~~~~
```

This is the second occurrence of the class recorded in
2026-08-16-pushed-main-did-not-compile.md, and it cost the same thing: the
error points at a `catch` in code the reading session had never touched, so the
first minutes go into deciding whose break it is.
[docs/runbooks/build-failure-not-yours.md](../../runbooks/build-failure-not-yours.md)
is that procedure.

## Reproduction

At `2ff411c9`, `zig build` fails with the error above. It reproduces from a
clean tree; the diff a session has in its worktree does not matter, which is
the quickest way to tell the two apart.

## Root cause

`cmdGoal` in `src/cli.zig` wrote the two `if` forms at once:

```zig
if (toolJson(...) catch null) |raw| {
    ...
} else |_| {}
```

`catch null` turns the error union into an optional, so the `if` is the
optional-unwrap form; `else |_|` is the error-union form and demands an error
union back. The caret lands on the `catch` rather than on the `else`, which is
why the reported line is the call and not the clause that is actually wrong.

The pattern one line below it (`parseFromSliceLeaky(...) catch null`) has no
`else`, and is what the corrected form looks like.

Reported by the authoring session when told of the break: its gate ran before
`git pull --rebase` and the push came after, so the gate never saw the tree it
pushed. Recorded as its own account, not as something checked here.

## Resolution

`395f912d` drops the `else |_| {}`. The `catch null` already turns a tool
failure into "no goal card recorded", which is the fail-open behavior that
block wants.

The authoring session added "A green gate does not survive a rebase" to
[the concurrent-sessions runbook](../../runbooks/concurrent-agent-sessions-on-one-checkout.md)
in `758c6fad`: re-verify after any rebase that pulled commits, `zig build` at
minimum.

## Verification

`zig build` green at `395f912d` in this checkout, and reported green by the
authoring session in its own checkout after pulling. The commit was landed
from an index narrowed to that one hunk, so it carries the one-line change
alone.

## Follow-up

## References

- Investigation: none yet
