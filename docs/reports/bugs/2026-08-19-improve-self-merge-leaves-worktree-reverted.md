# Bug — improve-self fast-forwards main's ref but leaves the working tree/index reverted to pre-promotion content

## TL;DR

- **What failed:** After imp-1787081817304037321 promoted and fast-forwarded main to 136e80b2 (adding a test to graph.zig), the actual working tree file and index still lacked the new test - git show HEAD had it, git diff HEAD did not. A blind commit-as-is pass right after promotion would have re-deleted the just-verified test. Fixed by git restore --source=HEAD --worktree, not yet root-caused in the merge-back code path.
- **Impact:** To be confirmed.
- **Resolution:** Investigating on 2026-08-18. Working tree/index restored locally to match HEAD (git restore --staged + --source=HEAD --worktree); the merge-back defect itself in the engine's fast-forward path is not yet root-caused or fixed.

## Status

Investigating on 2026-08-18. Working tree/index restored locally to match HEAD (git restore --staged + --source=HEAD --worktree); the merge-back defect itself in the engine's fast-forward path is not yet root-caused or fixed.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Symptom and impact

`clanker improve-self` run (task b9cyg0lut, instruction: find a recently added helper lacking test coverage) proposed and promoted a test for `finalAnswerPreview` in `src/agent/graph.zig`. The log showed:

```
gates green, promoting 1 file(s)
committed as git change: clanker: Add a unit test for finalAnswerPreview ... [imp-1787081817304037321]
improve-self: fast-forwarded main to 136e80b25760ae90872e4906065f1ad7bffdf92e
✓ promoted improvement imp-1787081817304037321 (gate 3.00/3)
final gate: 3.00/3 passing ... all gates passed
```

But immediately after the run exited, the main checkout's working tree told a different story:
- `git log --oneline -1` showed `136e80b2 ... [imp-...]`, with `git show 136e80b2 --stat` confirming the commit itself added the 20-line test.
- `git status -sb` showed `ahead 1` of origin AND a staged, unstaged-looking modification: `git diff --cached src/agent/graph.zig` showed a **20-line deletion** of the exact same test.
- `grep -n "finalAnswerPreview is UTF-8 safe" src/agent/graph.zig` on the actual file found nothing — the working tree file itself, not just the index, was missing the test.

So the ref (HEAD) was correctly advanced by the fast-forward, but the working tree and index of the main checkout were left in the *pre-promotion* state. Had the file been committed as-is at this point (e.g. by an automated `git add -A && git commit`), it would have re-deleted the test that was just verified and promoted, silently discarding the improvement while its commit message claimed it landed.
## Reproduction

Not yet isolated to a minimal repro. Observed once, live, after a successful `clanker improve-self ... --iters 1 --provider deepseek` run whose iteration 1 had two proposal attempts: attempt 1 errored out on a batch of unrelated validation noise (config parsing errors, schedule errors) rather than producing a clean patch; attempt 2 produced the promoted test-only proposal. The stale working-tree/index state matched attempt 1's pre-test baseline, suggesting the fast-forward (which only moves the ref) ran against a working tree/index that still held state from the earlier failed/reverted attempt in the same worktree, and nothing re-synced them to the new HEAD afterward.

## Root cause

Not yet found. Likely candidates in `src/improve/worktree.zig` / `src/improve/engine.zig`'s merge-back path (the code that fast-forwards main and is documented in AGENTS.md as "`Engine.run` end merges unpromoted commits back only behind fully green gate"): a fast-forward of the ref (`git` plumbing) does not by itself update a *working tree's* files or index — those need an explicit `git reset --hard` (or checkout) to the new HEAD in the main checkout after the ref moves, which appears to be missing or racing with a leftover attempt's staged state.
## Resolution

Not fixed at the source. Worked around locally in the main checkout:

```
git restore --staged src/agent/graph.zig     # index still had the stale deletion staged
git restore --source=HEAD --worktree -- src/agent/graph.zig   # working tree file itself lacked the test
```

Both were needed — restoring only the index left the working tree file still missing the test.
## Verification

- `grep -n "finalAnswerPreview is UTF-8 safe" src/agent/graph.zig` now finds the test.
- `zig build test` exit code 0 (checked directly, not through a pipe).
- `git status -sb` clean, ahead-of-origin by the one legitimate commit, no staged/unstaged diff.
- Pushed to origin without incident.

## Follow-up

The improve engine's merge-back needs to guarantee the main checkout's working tree and index are reset to the new HEAD after a fast-forward, not just the ref. Until root-caused, treat a post-promotion `improve-self` run as needing a `git status`/`git diff HEAD` sanity check before any automated commit pass touches the checkout — a blind "commit as is" immediately after a promotion can silently revert it.