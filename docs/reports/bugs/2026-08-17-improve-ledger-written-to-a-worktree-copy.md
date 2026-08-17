# Bug — The improve ledger is written to a worktree copy that is never merged back

## TL;DR

- **What failed:** Each improve-self run's state/ is a real directory inside its .clanker-worktrees/ copy, not a symlink to the shared state/, so every improvement it records lands there and is never merged back. The shared state/improvements.jsonl the next run reads has been frozen since 2026-08-16 12:00: of 25 imp- ids committed since, 23 are absent. The engine skips candidates history records as accepted or rejected, so it can re-propose what it already rejected.
- **Impact:** the loop cannot see what it already tried. AGENTS.md states the
  class is "recorded in \`state/improvements.jsonl\` and rendered in history
  block of next prompt, so loop sees what it produced", and the engine skips
  any candidate whose words history already records as accepted or rejected.
  A day and a half of that history is invisible, so rejected ideas can be
  re-proposed and the \`inert\`/\`test_only\` consecutive counters read from
  the same truncated history.
- **Resolution:** open. Not fixed — this record establishes the mechanism.
  A live hazard comes with it: those worktree ledgers are the only copy of the
  23 missing entries, and the only thing preserving them is \`clanker janitor\`
  currently refusing to remove the worktrees.

## Status

Open.

## Symptom and impact

No symptom. The loop keeps running, keeps committing, and keeps reporting
accepted improvements; only its memory of them is missing.

## Reproduction

Every command below was run in this checkout on 2026-08-17, and the output is
the actual output.

The shared `state/` is a symlink, and the improve worktrees' are not:

```
ls -ld state
```

```
state -> /home/yannick/code/ywy50/clanker-state/state
```

```
for d in .clanker-worktrees/*/state; do test -L "$d" && echo SYMLINK || echo REALDIR; done
```

Ten worktrees, ten `REALDIR`. That asymmetry is the whole defect: the checkout
and `clanker-state` are one file, so a run in the checkout appends where the
next run reads, while a run in a worktree appends to a private copy.

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

Open. Nothing is fixed here; the record establishes the mechanism and the
hazard so a fix can be scoped and the surviving history is not thrown away
first.

A fix has two halves that must not be confused:

1. **Stop the divergence.** Make the whole-file write follow the link
   instead of replacing it — resolve `state/improvements.jsonl` before the
   rename in `atomic_write.writeFile`, or write through the resolved target.
   Claimed on the board by session claude-20260817-135725, which holds
   `src/util/atomic_write.zig`. Note the fix is general: any symlinked file
   this helper rewrites has the same problem, not just the ledger.
2. **Recover the 23 entries.** They exist only in the worktree copies. Any fix
   that starts by cleaning up `.clanker-worktrees/` destroys them.

## Do not clean up the worktrees first

This is the live hazard and the reason this record exists now rather than
after a fix.

`clanker janitor` removes worktrees of archived or abandoned goals whose
branch is already merged, and every one of these branches is merged. It is
currently refusing them, which is the *only* thing preserving that history:

```
clanker janitor
```

```
worktrees:
  10 unrecognised in .clanker-worktrees/ -- an improve-self run may be using one right now, so these are never removed automatically
```

That refusal is incidental, not a safeguard for this. Anyone who makes the
janitor recognise these worktrees, or removes them by hand, deletes the only
copy of 23 accepted and rejected improvements. Salvage the ledger deltas
first — each worktree file is the shared 1130 lines plus its own appends, so
the delta is a tail.

## Verification

Every claim under Reproduction was run in this checkout on 2026-08-17 and its
output is quoted there: the `state` symlink, the ten `REALDIR` worktree state
directories, the line counts, the `grep -l` locating the missing id, the
25/2/23 id count, and the janitor refusal.

The 23-entry gap was established by session clanker-d7 and re-run here; the
mechanism above is session claude-20260817-135725's and was verified here by
the `history`-versus-`improvements.jsonl` control. Its counts and mine differ
by one at the boundary — it reports 24 ids with 1 in
the shared ledger, this record 25 with 2 — because the cutoff for "since the
ledger's last write" is picked slightly differently. The number that matters,
23 absent, is the same by both methods.

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

- Whether the same divergence affects the other run-scoped files a worktree
  copy writes — `state/runs/`, `state/token_stats.jsonl`, `state/autolearn.jsonl`
  — is not checked here. The ledger was found by looking for one id; nothing
  says it is the only file taking this path.
- No gate or check asserts that an improve worktree's `state` is a link.
  `clanker doctor` is the natural home for it.

## References

- Related bug: [`2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md`](2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md)
  — this was its unverified Follow-up item, chased down.
- Code: `src/improve/engine.zig` (`Worktree`, `mergeBack`, `cleanup`),
  `src/util/ensure_dir.zig`, `tools/zig/janitor.zig`
- Decision: ADR 0017 (an isolated run's `state` is a symlink)
