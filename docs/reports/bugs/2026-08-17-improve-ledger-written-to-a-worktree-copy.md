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

The improve engine stages each pass into a git worktree under
`.clanker-worktrees/`, and that copy gets a real `state/` directory rather
than a link to the shared one. The ledger append therefore succeeds — nothing
errors, nothing warns — into a file that is discarded with the worktree.

ADR 0017 and the `ensureDir` note in AGENTS.md both describe an isolated run's
`state` as a *symlink*, and `ck_fs_write_if` was given `ensureDir` precisely
because of it. The obvious reading is therefore that improve worktrees simply
never got that treatment.

That reading is wrong, and this record made it before checking. The engine
does try. `linkCheckoutStateAt` in `src/improve/worktree.zig` walks `host.shared_prefixes`
and symlinks `state` (named by `sharedDirectory`) from the worktree back to the
checkout, and its own comment describes exactly this failure -- "native
session/run writes later create a private `state/` in the worktree. The two
readers then disagree about the same run."

Nor is it stale code that postdates these worktrees: the linking landed in
`c6dfd690` on 08-14 23:41, and all ten worktrees were created on 08-17 between
11:23 and 16:17. The treatment is attempted, and something skips it.

**Which skip path fires is not established.** That function has exactly two --
`checkout.access(io, name, .{}) catch continue`, and `symLink(...)` with
`error.PathAlreadyExists => {}` -- and this record does not say which.

One piece of evidence rules out the obvious guess. The worktree `state` is not
a copy of the shared directory: it holds 11 entries against the shared
directory's 41 -- `autolearn.jsonl`, `improvements.jsonl`, `learnings.md`,
`reasoning.jsonl`, `runs`, `sessions`, `staging`, `token_stats.jsonl` and two
lock files, exactly the set an improve run writes. Nothing bulk-copied
`state/`; a private directory was created and populated. That fits the
`PathAlreadyExists` branch and not a wholesale copy, but the ordering that
would prove it has not been traced. The checkout's own `state` being a symlink
to `clanker-state` may matter to `access` and to `symLink` target resolution
here, and is worth checking first.

Only the merge-back crosses the worktree boundary, and it carries commits, not
state. `Worktree.merged` answers "did promotion land?" — it says nothing about
files outside the git tree, and `state/` is gitignored.

## Resolution

Open. Nothing is fixed here; the record establishes the mechanism and the
hazard so a fix can be scoped and the surviving history is not thrown away
first.

A fix has two halves that must not be confused:

1. **Stop the divergence.** Find which of the two skip paths in
   `linkCheckoutStateAt` fires and close it, so the append lands in the shared
   ledger. The intent and the code are already there (ADR 0017, `c6dfd690`);
   this is a link that is attempted and silently not made, which is why no
   layer reports anything.
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

The mechanism was established by session clanker-d7 and re-run here. Its
counts and mine differ by one at the boundary — it reports 24 ids with 1 in
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
