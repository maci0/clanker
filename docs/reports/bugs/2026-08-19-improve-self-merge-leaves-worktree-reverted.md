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
## Second occurrence (confirmed pattern)

Reproduced again on the very next promoted run: imp-1787083378744109070 ("Correct the stale `zig build tools` comment..."), fast-forwarded main to 1a7fca35. Same shape exactly:

- `git status -sb` after the run exited: `ahead 1`, `M  build.zig` staged.
- `git diff --cached build.zig` was the *exact inverse* of the promoted commit's diff — reverting the corrected comment back to the stale one.
- Working tree file (not just index) held the reverted content, confirmed via grep before/after restore.

Both occurrences promoted a small `test_only`/comment-only change whose capability evals needed a retry ("capability evals: N case(s) failed; retrying only those" -> "PASS on retry") before going green. That retry step is now the strongest lead for where the stale worktree/index state leaks back into the main checkout — worth checking whether the retry path re-applies the *original* (pre-fix) staged copy for its second attempt and that copy is what ends up synced into main after promotion, rather than the version that actually passed.

Fixed the same way: `git restore --staged` then `git restore --source=HEAD --worktree`. Both fixes verified with a clean `zig build test` (exit 0) before pushing.
## Third occurrence, and a confirmed structural lead

Third promoted run, same shape again: imp-1787085004582376221 ("Preallocate the converted message list in advisor.summarizeTurn..."), fast-forwarded to 31471696, one capability eval failed and passed on retry, then `src/agent/advisor.zig` was found staged with the exact inverse diff. Now 3/3 promoted runs today share this pattern: a `test_only` or `behavior`-class change, a capability-eval retry, and a post-promotion revert of exactly the file the proposal touched. Fixed the same way (restore --staged + --source=HEAD --worktree), verified with `zig build test` exit 0, pushed.

**Confirmed structural fact, not yet tied definitively to the symptom:** `state/staging/<id>/` (created by `prepareStaging`/`copyTreeInto`, a plain byte-for-byte file copy, not a `git worktree add`) has no `.git` of its own — verified directly:

```
ls state/staging/<any-old-id>/.git   # No such file or directory
```

Both `capabilityGate` and `capabilityGateRetry` (src/improve/engine.zig ~2042, ~2099) spawn `clanker eval <name>` as a **live LLM agent subprocess** with `.cwd = .{ .dir = staged_dir }`. Any capability eval whose `requires_tool` is `git` (`git_allow`, `git_deny`) has that subprocess run real `git` commands rooted at `staged_dir`. Because that directory has no `.git`, git's normal upward search resolves those commands against the **live checkout's** `.git`, not an isolated copy — `git_deny` specifically prompts the eval agent to attempt `git reset --hard`, which is supposed to be denied by the sandbox's exec policy but, if it or a similar destructive/restoring git command ever slips through (a policy gap, or the model choosing a slightly different-but-still-broad command while "retrying"), would act on the live repository's working tree rather than a disposable copy.

This does not yet fully explain the *exact* symptom (the revert lands on the specific file the proposal touched, and pre-promotion the live tree has nothing to revert for that eval's timing), but it is a real, verified hazard on its own: every capability gate run — success or failure — executes real git subprocesses with a shared `.git`, and `state/staging/` is a subdirectory of the live checkout rather than an isolated tree.