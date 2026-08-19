# Investigation — Stale post-promotion checkout diff on doctor.zig was committed and pushed as revert 124d592e

## TL;DR

- **Question:** Two improve-self promotions to src/doctor.zig merged from the engine's worktree; mergeBack moved main's ref without resyncing the invoking checkout, which then showed the inverse diff as an unstaged change blocking git pull. Committing that diff to unblock the pull pushed 124d592e, deleting both promotions from origin/main. Reapplied on reapply-doctor-improvements, gate green.
- **Finding:** Resolved on 2026-08-19. mechanism fixed as 53b26a9e (mergeBack resyncs the invoking checkout when clean, warns and never resets a dirty one; unit-tested in worktree.zig) on top of the reopened bug record; the deleted promotions were reapplied via PR #266 (820b61de), on main. Recovery for any stale diff met in the wild is in the linked bug: restore, never commit it
- **Resolution:** Resolved on 2026-08-19. mechanism fixed as 53b26a9e (mergeBack resyncs the invoking checkout when clean, warns and never resets a dirty one; unit-tested in worktree.zig) on top of the reopened bug record; the deleted promotions were reapplied via PR #266 (820b61de), on main. Recovery for any stale diff met in the wild is in the linked bug: restore, never commit it

## Status

Resolved on 2026-08-19. mechanism fixed as 53b26a9e (mergeBack resyncs the invoking checkout when clean, warns and never resets a dirty one; unit-tested in worktree.zig) on top of the reopened bug record; the deleted promotions were reapplied via PR #266 (820b61de), on main. Recovery for any stale diff met in the wild is in the linked bug: restore, never commit it

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
## Timeline (all times 2026-08-19 +0800, from git author dates)

- 09:39 — 68726302 promoted: manifests check FAILs on zero registered tools (imp-1787102961990565171).
- 10:00 — 6b7e4030 promoted: version/platform in doctor's header line (imp-1787104236888936691). Both ids recorded status accepted in state/improvements.jsonl (grep over the ledger).
- Both promotions ran in the engine's .clanker-worktrees/ worktree and landed on main via Worktree.mergeBack.
- After the merges, the operator's main checkout showed src/doctor.zig as an unstaged change never made by hand, and git pull refused with the unstaged-change error (operator account; the checkout was clean again before this trace ran, so not independently reproduced).
- 10:12 — 124d592e committed and pushed to clear the blocked pull. It touches only src/doctor.zig, +2/-19.

## Evidence that 124d592e is the pre-promotion copy, not an intentional revert

'git revert --no-commit 124d592e' against the origin/main tip stages exactly +19/-2 on src/doctor.zig — the combined diff of the two promotions. The commit is the byte-exact inverse of both, which is what committing a checkout still holding pre-promotion content produces.

## Mechanism

Already root-caused in the linked bug: Worktree.mergeBack's fast-forward moves the shared branch ref via update-ref and then runs 'git -C <worktree> reset --hard' pinned to the engine's own throwaway worktree (src/improve/worktree.zig), deliberately never touching the invoking checkout. A ref move alone updates neither that checkout's index nor its working tree, so both keep pre-promotion bytes and git presents the inverse diff as local modifications. Every promotion invoked from a checkout sitting on the merged branch reproduces this; what was new here is that the diff got committed and pushed instead of restored.

## Recovery

Branch reapply-doctor-improvements from origin/main, 'git revert 124d592e' (commit 820b61de) plus the CHANGELOG Unreleased entry the promotions never added. clanker gate: build, tests, tools, fmt, lint, provider-kind, test-root-coverage, tools-ts-toolchain, release-contract all PASS. Landed via PR.

## References

- Bug (reopened): docs/reports/bugs/2026-08-19-improve-self-merge-leaves-worktree-reverted.md
- The correct manual recovery when the stale diff appears, from that bug: git restore --staged <file>, then git restore --source=HEAD --worktree -- <file> — never commit the diff.