# Bug — The improve ledger is written to a worktree copy that is never merged back

## TL;DR

- **What failed:** An improve worktree's state/improvements.jsonl is symlinked back to the checkout's, and the first whole-file rewrite of it replaces that link with a private regular file: atomic_write.writeFile is temp-file-plus-rename, and a rename lands on the *link itself*. Every append the run makes afterwards is discarded with the worktree. The shared ledger was frozen from 2026-08-16 12:00 until it was backfilled on 2026-08-17; of the 24 imp- ids committed in that window 21 are absent from it and no copy of them survives. The engine skips candidates history records as accepted or rejected, so it can re-propose what it already rejected.
- **Impact:** the loop cannot see what it already tried. AGENTS.md states the
  class is "recorded in \`state/improvements.jsonl\` and rendered in history
  block of next prompt, so loop sees what it produced", and the engine skips
  any candidate whose words history already records as accepted or rejected.
  A day and a half of that history is invisible, so rejected ideas can be
  re-proposed and the \`inert\`/\`test_only\` consecutive counters read from
  the same truncated history.
- **Resolution:** Resolved on 2026-08-17. atomic_write.writeFile renames onto a symlinked destination's target instead of onto the link, so an improve worktree's linked state/improvements.jsonl and config.local.toml keep their links; three unit tests, the first failing NotLink on the old code. Recovery first: the ten worktree ledgers were drained into the shared one (1130 to 1139) and the three reverted entries restored. zig build test 1510/1521, clanker gate 8/8.
  link target and renames onto *that*, so a linked path keeps its link and the
  write lands where every reader looks. Three unit tests cover the
  same-directory, relative-subdirectory and absolute link-target spellings; the
  first fails with \`NotLink\` on the old code. The surviving worktree ledgers
  were drained into the shared one before the fix landed (1130 → 1139 lines,
  exactly the ten worktrees' combined delta), so the do-not-clean-up hazard
  below is retired.

## Status

Resolved on 2026-08-17. atomic_write.writeFile renames onto a symlinked destination's target instead of onto the link, so an improve worktree's linked state/improvements.jsonl and config.local.toml keep their links; three unit tests, the first failing NotLink on the old code. Recovery first: the ten worktree ledgers were drained into the shared one (1130 to 1139) and the three reverted entries restored. zig build test 1510/1521, clanker gate 8/8.

## Symptom and impact

No symptom. The loop keeps running, keeps committing, and keeps reporting
accepted improvements; only its memory of them is missing.

## Reproduction

Every command below was run in this checkout on 2026-08-17, and the output is
the actual output.

The checkout's `state/` is a symlink to durable storage, and the improve
worktrees' are real directories:

```
ls -ld state
```

```
state -> /home/yannick/code/ywy50/clanker-state/state
```

```
for d in .clanker-worktrees/*/state; do test -L "$d" && echo SYMLINK || echo REALDIR; done
```

Ten worktrees, ten `REALDIR`. **This is not the defect** — read as one it sent
two sessions after the wrong function, and the Root cause section below
untangles it. A real `state/` is what `linkSharedState` is written to produce
for an improve worktree. The defect is one level down, in the two entries
inside it that *are* linked back to the checkout:

```
ls -l .clanker-worktrees/*/state/improvements.jsonl .clanker-worktrees/*/state/history
```

Ten `history` symlinks, and ten `improvements.jsonl` regular files — same
provisioning loop, same list, different outcome.

Each worktree ledger is the shared file plus that run's own appends:

```
wc -l state/improvements.jsonl .clanker-worktrees/*/state/improvements.jsonl
```

The shared file is 1130 lines; the worktrees are 1130, 1130, 1130, 1130, 1130,
1130, 1131, 1131, 1133, 1134.

The improvement that started this — `imp-1786938760641431811`, from
[the config-hunk record](2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md)
— exists, just not where anything will read it:

```
grep -l 1786938760641431811 .clanker-worktrees/*/state/improvements.jsonl
```

```
.clanker-worktrees/1786937610892110663-main/state/improvements.jsonl
```

Scale of the gap, counting distinct `imp-` ids in commit subjects since the
shared ledger's last write (`ls -l` gives 2026-08-16 12:00) and testing each
against that ledger:

| | |
|---|---|
| distinct `imp-` ids committed since | 25 |
| present in the shared ledger | 2 |
| absent from it | **23** |

## Root cause

An improve worktree's `state/` is a real directory *by design*, not by
accident. `linkSharedState` in `src/improve/worktree.zig` builds it that way:
`createDirPath` makes `state/`, `state/runs/` and `state/sessions/` as real
directories, and then symlinks exactly two entries back to the checkout —
`state/improvements.jsonl` and `state/history`.

The split is deliberate, and the function says why: "The dividing line for
everything under state/ is WHO reads the path." A symlink is safe only where
the *host* reads it, because `safeJoinSecure`'s no-follow walk correctly
refuses symlinked components for any path a sandboxed tool traverses — a
linked `state/runs` broke graph's write test in every worktree, and a linked
`learnings.md` denies the learnings tool. `improvements.jsonl` qualifies for a
link precisely because only the engine's `History` touches it.

So the ledger *is* linked, and the link is correct. What breaks it is the
write. `atomic_write.writeFile` is a temp file plus an atomic rename, and a
rename onto `state/improvements.jsonl` replaces **the symlink itself** with a
real file. Every append after that is private to the worktree and is thrown
away with it.

The proof sits in the same directory, as a control. Of the two linked entries,
one is still a link and one is not:

```
lrwxrwxrwx history -> /home/yannick/code/maci0/clanker/state/history
-rw-r--r-- improvements.jsonl
```

`history` is a directory: nothing rename-rewrites it, so its link survives.
`improvements.jsonl` is a file that gets whole-file rewrites, so it does not.
The other real files beside them — `autolearn.jsonl`, `learnings.md`,
`reasoning.jsonl`, `token_stats.jsonl` — were never linked at all, by the
sandbox rule above, so they are not evidence of anything.

### Two earlier accounts in this record were wrong

Both are left visible because each was stated more confidently than it was
checked, which is the failure this store exists to prevent.

1. The first said improve worktrees "do not get that treatment, and nothing
   checks that they do" — that the `state` symlink was simply never made.
2. The second corrected it to `linkCheckoutStateAt` attempting the link and
   something skipping it, and named two skip paths. That is the wrong
   function: `linkCheckoutStateAt` links whole shared directories for
   *isolated runs*; the improve worktree path is `linkSharedState`, which
   deliberately does not link `state/` as a directory at all.

The evidence that settles it — `history` still linked beside an unlinked
`improvements.jsonl` — was available from the first `ls -la` and was not run
until session clanker-55 questioned whether a rename could produce a real
directory. It cannot, and that objection is also wrong: a rename through a
*directory* symlink lands inside the target, but `improvements.jsonl` is a
symlink to a *file*, and a rename onto it replaces the link. The mechanism
claimed by session claude-20260817-135725 was right from the start.

Only the merge-back crosses the worktree boundary, and it carries commits, not
state. `Worktree.merged` answers "did promotion land?" — it says nothing about
files outside the git tree, and `state/` is gitignored.

## Resolution

Fixed, in both halves, in that order — the recovery had to come first because
the fix does not resurrect anything.

**1. The surviving entries were recovered.** The ten worktree ledgers were
drained into the shared one before any code changed: 1130 → 1139 lines, and
the ten worktrees' deltas over the shared 1130 sum to exactly those 9
appended entries (1+3+0+1+0+0+0+0+4+0).

That left a second, quieter loss the line counts do not show. Every one of the
ten copies also differed from the shared ledger on the *same three existing
lines* — `imp-1786839734969828365`, `imp-1786843447727583732` and
`imp-1786846507181256994`, each `"status":"reverted"` in the worktrees and
still `"status":"accepted"` in the shared file, with the reason field
populated only in the worktrees:

```
"detail":"removed from the tree without a revert commit: every line this change added is gone"
```

That is `markReverted`'s own output, and it is also the write that broke the
link: three flips is why the rewrite ran at all, and because the flip never
reached the shared ledger every later run re-found the same three reverts and
re-clobbered its own link. The shared ledger has since been given those three
lines verbatim from a worktree copy, so `alreadyAccepted` and `clanker revert`
no longer read three human-reverted changes as accepted. Re-checking now, no
line in any of the ten worktree ledgers is absent from the shared one.

Nothing beyond that was recoverable. Of the 24 `imp-` ids in the last 200
commit subjects, 21 are absent from the shared ledger *and* from every
surviving worktree copy — their worktrees were removed before anyone knew the
entries lived only there. Those 21 are gone.

**2. The divergence is stopped.** `atomic_write.writeFile` now reads the
destination's link target and renames onto *that* instead of onto the link:

- a relative target resolves against the directory holding the link, not
  against `dir`;
- an absolute target — the spelling `linkSharedState` writes — is used as-is,
  because `openat` ignores the directory handle for an absolute path;
- a path that is not a link, or does not exist yet, is written exactly as
  before.

The fix is general, not ledger-specific: every caller of this helper had the
same defect on any symlinked destination. `config.local.toml` is the other one
that is linked into an improve worktree today (`linkSharedState`), and
`src/config.zig` rewrites it through this helper.

Three unit tests in `src/util/atomic_write.zig` cover the three link spellings;
the first fails with `NotLink` on the old code, and the whole suite is green
with the new one.

## The clean-up hazard, now retired

While this record was open, the ten worktree ledgers held the only copy of
every entry those runs had written, and `clanker janitor` was refusing to
remove the worktrees for an unrelated reason:

```
clanker janitor
```

```
worktrees:
  10 unrecognised in .clanker-worktrees/ -- an improve-self run may be using one right now, so these are never removed automatically
```

That refusal was incidental, not a safeguard. It is no longer load-bearing:
the deltas have been merged into the shared ledger (see Resolution), and
re-checking each worktree copy for an id the shared ledger lacks now finds
nothing. The worktrees can be removed like any other.

The general lesson outlives the instance. A worktree's `state/` is not part of
the git tree, so nothing about "the branch is merged" says its files were
salvaged; `Worktree.merged` answers a question about commits only. Any change
that makes the janitor recognise improve worktrees should still assume there
is unmerged non-git state inside one.

## Verification

Every claim under Reproduction was run in this checkout on 2026-08-17 and its
output is quoted there: the `state` symlink, the ten `REALDIR` worktree state
directories, the line counts, the `grep -l` locating the missing id, the
25/2/23 id count, and the janitor refusal.

The entry gap was established by session clanker-d7 and re-run here; the
mechanism above is session claude-20260817-135725's and was verified here by
the `history`-versus-`improvements.jsonl` control. The counts differ by one at
the boundary — clanker-d7 reports 24 ids with 1 in the shared ledger, an
earlier draft of this record 25 with 2 — because the cutoff for "since the
ledger's last write" is picked slightly differently. The final count against
the last 200 commits is 24 ids with 3 present, 21 absent, and it is the same
21 by every method tried.

### The fix, and what proves each half

Both of these are commands run in this checkout on 2026-08-17, not inference.

**That the writer was `markReverted`, not some other whole-file write.** Each
of the ten worktree copies is the shared ledger's full 1130 lines — it goes
back to `imp-1786470823400993382`, months before that worktree existed — plus
its own appends. A file created fresh, because the link was never made, would
hold only its own run's entries. So the link existed and was read through, and
then something rewrote the whole file. Diffing the shared prefix names what:
three lines, all of them `"status":"accepted"` → `"status":"reverted"` with a
`detail` reason added. That is `markReverted` and nothing else in the module
writes that shape.

**That all ten worktrees are improve worktrees**, so `linkSharedState` and not
`linkCheckoutStateAt` provisioned them — the distinction the corrections above
turn on:

```
for d in .clanker-worktrees/*/; do git -C "$d" rev-parse --abbrev-ref HEAD; done
```

Ten branches, every one `clanker/improve-self-<id>-main`. `createOn` passes
`.improve` for that prefix and `.run` for `clanker/run-`, `clanker/webui-` and
`clanker/tui-`; only the `.run` arm reaches `linkCheckoutStateAt`.

**That the fix works.** Three unit tests in `src/util/atomic_write.zig` cover
the three link-target spellings — same directory, relative in a subdirectory,
and absolute. Reverting only the implementation and keeping the tests fails
exactly one, and for the right reason:

```
error: 'util.atomic_write.test.writeFile follows a symlinked destination instead of replacing the link' failed:
       link.jsonl is no longer a symlink: NotLink
Build Summary: 295/297 steps succeeded (1 failed); 1507/1519 tests passed (11 skipped, 1 failed)
```

With the implementation restored: `zig build test` 1510/1521 passed (11
skipped), and `clanker gate` 8/8, both in a clean worktree at the same commit
so no other session's in-flight edits are in the tree.

**That the recovery is complete.** No line of any of the ten worktree ledgers
is missing from the shared one:

```
for w in .clanker-worktrees/*/state/improvements.jsonl; do grep -Fvx -f state/improvements.jsonl "$w" | wc -l; done
```

Ten zeros. Before the three flips were applied it printed ten threes.

### Correction

This record's predecessor,
[the config-hunk record](2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md),
carried a claim under a "Not verified" heading: that the shared ledger still
listed `imp-1786938760641431811` as accepted. That claim was wrong — the id is
not in the shared ledger at all — and it was flagged as unverified by the
session that made it, then checked rather than repeated. The truth is worse
than the original claim: not one improvement missing its budget, but a day and
a half of history the loop cannot see. Left visible here rather than smoothed
away, because the reason it was caught is that it was marked unverified.

## Follow-up

### Checked: the other run-scoped files an improve worktree writes

This was open — "the ledger was found by looking for one id; nothing says it
is the only file taking this path." It is now answered, and the answer is that
`state/runs/`, `state/token_stats.jsonl` and `state/autolearn.jsonl` are not
instances of this defect.

They are not linked in the first place. `linkSharedState` links exactly two
entries and copies a third set; the rest is deliberately worktree-local, and
its own comment says why: "Runtime state (runs, sessions, stats, reasoning
traces, plugin toggles) is deliberately neither linked nor copied: a fresh
worktree legitimately starts empty." A file that was never a link cannot have
its link replaced. Whether that isolation is the right policy is a separate
question from this record; it is at least an intended one, and it is recorded
in code.

What the defect's scope actually is: **any leaf symlink** whose destination is
rewritten through `atomic_write.writeFile`. Directory symlinks are not
affected, which is why `state/history` survived in all ten worktrees and why
the checkout's own `state -> clanker-state/state` was never at risk — a rename
resolves the directory components of its target and lands *inside* them,
touching only the final name. Beside the ledger, the one other leaf link an
improve worktree gets today is `config.local.toml`, and `src/config.zig`
rewrites it through this same helper. Both are fixed by the same change.

### Still open: nothing asserts the links survive

No gate or check asserts that an improve worktree's linked entries are still
links. The unit tests added here pin the *write* helper's behaviour, which is
where this defect lived, but they would not catch a future caller that
rewrites a linked path some other way. `clanker doctor` remains the natural
home for that assertion.

## References

- Related bug: [`2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md`](2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md)
  — this was its unverified Follow-up item, chased down.
- Code: `src/improve/engine.zig` (`Worktree`, `mergeBack`, `cleanup`),
  `src/util/ensure_dir.zig`, `tools/zig/janitor.zig`
- Decision: ADR 0017 (an isolated run's `state` is a symlink)
