# Bug — A stray config.toml hunk reverts to the struct default and nothing surfaces it

## TL;DR

- **What failed:** 0bee7594, a CAS-lock commit with the subject 'commit', also deleted the three lines of [improve] max_context_requests = 5 that c4fdc685 had added eight minutes earlier. The key silently fell back to src/config.zig's default of 3 for nine hours. A stray hunk in source self-heals through the improve engine's merge-back, a refactor, or a failing test; a stray hunk in config has none of those.
- **Impact:** the improve loop ran with a context-request budget of 3 while the
  tree said 5, from 12:07 to 21:25 on 2026-08-17 (9h18m). The general impact is
  the class, not the instance: this repo keeps `config.toml` and the struct
  defaults in `src/config.zig` deliberately in step, so a deleted key is not a
  parse error and not a missing symbol — it is a silent change of behaviour
  that reads as normal.
- **Resolution:** Resolved on 2026-08-17. Restored in d19dc878 by session clanker-d7; verified here with clanker --dump-config (max_context_requests = 5) and git show on all three commits. No code change: the record exists for the auditing method and the config-vs-source asymmetry.

## Status

Resolved on 2026-08-17. Restored in d19dc878 by session clanker-d7; verified here with clanker --dump-config (max_context_requests = 5) and git show on all three commits. No code change: the record exists for the auditing method and the config-vs-source asymmetry.

## Symptom and impact

There is no symptom. That is the finding.

`[improve] max_context_requests` lets an improve-self pass ask to be shown a
file it has not been given, instead of proposing an exact-match patch against
text it never saw. `c4fdc685` raised it from the default 3 to 5. Eight minutes
later it was gone again, and nothing anywhere reported that: no parse error
(the key is optional), no missing symbol (nothing references the TOML), no
failing test (no test asserts the value), no gate. `clanker gate` was green
across the whole window.

## Reproduction

Not a race and not environment-dependent — it is visible in the history.
Commands run on 2026-08-17 in this checkout; each line is the actual output.

The key was added:

```
git show c4fdc685 -- config.toml
```

```
+++ b/config.toml
+max_context_requests = 5
```

The key was deleted eight minutes later, by a commit about something else:

```
git show 0bee7594 --stat
```

```
 config.toml                                        |   3 -
 docs/reports/README.md                             |   2 +
 ...8-17-ck-cas-lock-sidecars-still-accumulating.md |  25 +++
 src/sandbox/host.zig                               | 173 ++++++++++++++++++++-
 src/util/log.zig                                   |   2 +-
 tools/zig/janitor.zig                              |  18 ++-
 6 files changed, 210 insertions(+), 13 deletions(-)
```

`0bee7594` is the ADR 0031 CAS-lock-sidecar change. Its subject is the single
word `commit`. The `config.toml` hunk has nothing to do with its purpose:

```
git show 0bee7594 -- config.toml
```

```
-max_context_requests = 5
```

Timeline, from `git log --date=format:'%m-%d %H:%M'`:

| commit | time | what |
|---|---|---|
| `c4fdc685` | 08-17 11:59 | raises the budget to 5 |
| `0bee7594` | 08-17 12:07 | deletes it as collateral |
| `d19dc878` | 08-17 21:25 | restores it |

## Root cause

Two separate things, and only the second is interesting.

**The deletion.** Most likely `config.toml` was written whole from a copy read
before `c4fdc685` landed, rather than edited in place — the hunk is a clean
removal of exactly the three lines that commit added, in a commit that touches
nothing else related. *Unverified*: this is the shape the diff has, not
something established from the authoring process, and the subject `commit`
carries no information about it. Six commits in the last seven days have that
same one-word subject (`b05e6048`, `be623ddd`, `7d210d51`, `502ae662`,
`0bee7594`, `ed634269`), which is what made the audit expensive.

**Why nine hours passed.** A stray hunk in *source* self-heals, by three
independent routes: the improve engine's merge-back restores it, a later
refactor carries the functionality under a new name, or a test fails. A stray
hunk in *config* has none of them. `src/config.zig` supplies a struct default
for every key, and AGENTS.md documents that `config.toml` and those defaults
are deliberately kept in step — so a deleted key parses cleanly, resolves to a
value that looks reasonable, and changes behaviour with no signal at all:

```
grep -n "max_context_requests" src/config.zig
```

```
694:    max_context_requests: u32 = 3,
```

That symmetry is a feature for operators and a blind spot for auditing. It is
the same property AGENTS.md already warns about in the improve loop —
"flipping a default there equals writing \`= false\` in config" — read from
the other direction.

## Resolution

Restored in `d19dc878` (`config.toml`, +3 lines) by session clanker-d7.

No code change. What this record is for is the auditing method, because the
next stray config hunk will be as quiet as this one.

## Verification

Verified in this checkout on 2026-08-17 by running each command below.

The key is in effect again:

```
clanker --dump-config | grep max_context_requests
```

```
max_context_requests = 5
```

`c4fdc685` adding it, `0bee7594` deleting it and `d19dc878` restoring it were
each confirmed with `git show`, as quoted under Reproduction. The struct
default of 3 was confirmed at `src/config.zig:694`.

### Resolved: it was the first case, and it is its own defect

This record originally carried a claim from the clanker-d7 audit that the
shared ledger still listed `imp-1786938760641431811` as accepted, so the loop
believed it had a budget it did not have. That claim was flagged unverified
here rather than repeated, because the id is in no ledger this checkout reads.

It has since been chased down and is **not** true, and the truth is worse:
the improve engine appends its ledger to a real `state/` directory inside each
`.clanker-worktrees/` copy, which is never merged back. The shared ledger has
been frozen since 2026-08-16 12:00 and 23 of 25 committed `imp-` ids are
absent from it, so a day and a half of accepted and rejected improvements are
invisible to the next run. The two ledgers this record could not tell apart
were one file: the checkout's `state` is a symlink to `clanker-state`.

That has its own record, including a live hazard about not cleaning up the
worktrees:
[`2026-08-17-improve-ledger-written-to-a-worktree-copy.md`](2026-08-17-improve-ledger-written-to-a-worktree-copy.md).

The reason it was caught is that it was written down as unverified instead of
being smoothed into the narrative.

## Method traps

Both from the clanker-d7 audit; recorded because each nearly produced a false
report, and both will recur on any audit of the improve engine's history.

1. **patch-id is meaningless on a merge commit.** `54fc2ab4` is flagged as not
   upstream by `git cherry` / patch-id and is simply the engine's merge-back
   (parents `502ae662` + `3bf57ab2`); its second parent is landed. Read as a
   patch-id miss it is a phantom loss.
2. **A merge-back's first parent reads as a mass revert.** `502ae662` genuinely
   deletes 106 lines of the loop's alarm / bugreport / reports / autolearn
   work, and is harmless: it is the first parent of that same merge, and the
   merge restores all of it. Read standalone it looks like someone reverted an
   afternoon.

The audit that produced those also checked the other vague-subject commits per
line and found them clean — `ed634269` is a rename (`lock_holder_record_len` →
`cas_lock_record.record_len`, janitor's `Kind` extended rather than cut),
`b05e6048` drops debug scaffolding while `mesh_cmd.cmd` is still called at
`src/cli.zig:6054`, and `0bee7594`'s `ck_cas.lock` deletion is ADR 0031 working
as intended. Eight recent `imp-` changes were checked by added-line presence
and all were fully present. Those results are carried across from that session
and were not re-run here.

## Follow-up

- Six commits in seven days with the literal subject `commit`: `b05e6048`,
  `be623ddd`, `7d210d51`, `502ae662`, `0bee7594`, `ed634269` (all authored
  `ywy50`). A one-word subject is what forced a per-line audit. Whether a
  session or the harness produces them is not traced.
- Nothing checks that a commit's `config.toml` hunk belongs to its subject.
  A gate cannot judge intent, but "this diff touches `config.toml` and its
  subject mentions neither config nor a key name" is a cheap warning, and
  `clanker commit` already groups a diff by topic.
- The ledger gap above turned out to be its own defect and has its own record:
  [`2026-08-17-improve-ledger-written-to-a-worktree-copy.md`](2026-08-17-improve-ledger-written-to-a-worktree-copy.md), open.

## References

- Related bug: [`2026-08-17-ck-llm-grant-spent-on-reasoning.md`](2026-08-17-ck-llm-grant-spent-on-reasoning.md)
  — the same shape one layer down: a budget that is wrong in a way nothing reports.
- Code: `config.toml` (`[improve]`), `src/config.zig:694`
  (`max_context_requests`), `src/improve/engine.zig`
- Commits: `c4fdc685` (added), `0bee7594` (deleted), `d19dc878` (restored)
