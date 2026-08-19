# Bug — improve-self fast-forwards main's ref but leaves the working tree/index reverted to pre-promotion content

## TL;DR

- **What failed:** After imp-1787081817304037321 promoted and fast-forwarded main to 136e80b2 (adding a test to graph.zig), the actual working tree file and index still lacked the new test - git show HEAD had it, git diff HEAD did not. A blind commit-as-is pass right after promotion would have re-deleted the just-verified test. Fixed by git restore --source=HEAD --worktree, not yet root-caused in the merge-back code path.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-19. mergeBack now resyncs the checkout holding the base branch when its index and files match the pre-merge base SHA, and warns instead of resetting a dirty one (resyncBaseCheckout); verified by a real-repo integration test plus the checkoutOf unit test, full gate green on the rebased branch

## Status

Resolved on 2026-08-19. mergeBack now resyncs the checkout holding the base branch when its index and files match the pre-merge base SHA, and warns instead of resetting a dirty one (resyncBaseCheckout); verified by a real-repo integration test plus the checkoutOf unit test, full gate green on the rebased branch

## Symptom and impact

## Reproduction

## Root cause

## Resolution

Fixed at the source on 2026-08-19, taking the resync side of the tradeoff the
fourth-occurrence investigation left open — with the guard that answers its
objection. `Worktree.mergeBack` now calls `resyncBaseCheckout` after every
successful CAS (both the fast-forward and the merge-commit branch): it finds
the checkout that has the base branch checked out via
`git worktree list --porcelain` (`checkoutOf`, a pure parser), and runs a
bare `git -C <checkout> reset --hard` there **only when that checkout's index
and working tree are both byte-identical to the pre-merge base commit**
(`matchesCommit`: `diff --cached --quiet <old-sha>` and
`diff --quiet <old-sha>` both clean). A checkout carrying its own
work-in-progress is never reset; it gets a warning naming the checkout, the
do-not-commit-the-inverse hazard, and the manual sync. The reset is
deliberately bare: HEAD already points at the moved ref and a no-argument
reset cannot move a ref, so a concurrent commit landing between the CAS and
the resync is not rewound.

The uncommitted-work hazard that made the investigation defer this is exactly
what the clean-vs-pre-merge-SHA guard removes: a checkout that was clean at
the old base loses nothing to `reset --hard`, because everything it held is
what the promotion replaced, and untracked files are untouched by definition.

## Verification

- Host test `checkoutOf finds the one worktree holding a branch`
  (`src/improve/worktree.zig`): porcelain parsing, including a detached entry
  and a branch-name prefix that must not match.
- Integration test
  `mergeBack's resync reaches the invoking checkout only when it is clean`
  (`src/improve/worktree.zig`): builds a real repository plus a linked
  worktree, moves the base ref exactly the way `mergeBack` does
  (`update-ref`, no checkout touched), and asserts the clean primary is
  synced to the promoted content with no tracked diff — then dirties the
  primary, moves the ref again, and asserts the file is left alone.
- Full gate green on the fix branch rebased onto main:
  `zig build`, `zig build tools`, `zig build test --summary all` —
  320/320 steps, 1673/1684 passed, 11 skipped, 0 failed; exit code read
  directly, not through a pipe. (Three runs before the green one wedged in
  the known intermittent never-answering-provider hangs —
  [2026-08-18-bounded-chat-abort-test-hangs](../investigations/2026-08-18-bounded-chat-abort-test-hangs.md)
  — and were killed and rerun per that investigation.)
- Not re-verified end-to-end with a live `improve-self` promotion: driving
  the improve loop to a promotion needs the model to produce a promotable
  change on cue. The integration test reproduces the exact ref-move the live
  failures performed, against real git.

## Follow-up

- AGENTS.md's improve section still tells an operator to expect the inverse
  diff and restore by hand; once this fix has survived a few live
  promotions, that paragraph can be softened to cover only the
  dirty-checkout case the warning now names.

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
## Fourth occurrence — falsifies the retry theory, and the real root cause

Fourth promoted run, imp-1787086617067521436 ("Graph.add keeps the latest output preview when it collapses a repeated node"), fast-forwarded to 6f010350. This time capability evals **passed on the first try, no retry at all** — yet `src/agent/graph.zig` was again found staged with the exact inverse diff after the run exited. 4/4 promoted runs today reverted the calling checkout; 3/4 needed an eval retry and 1/4 did not. That rules out the eval-retry theory from the prior two updates as the cause — it happened even with zero retries, so it must be unconditional on every promotion.

**Confirmed root cause**, found by reading the actual merge path this time (`src/improve/worktree.zig`, not the direct-write promote loop in `engine.zig` I'd read earlier for a different, unused code path):

`Worktree.mergeBack`'s fast-forward branch (worktree.zig ~163-176) does exactly two things on success:
1. `updateRefCas`: a bare `git update-ref refs/heads/<base> <new_sha> <old_sha>` — moves the **shared** ref, nothing else. `git update-ref` never touches any checkout's working tree or index.
2. `resyncLocalBranch`: `git -C <isolated-worktree-path> reset --hard <new_sha>` — resets **only the improve-self run's own throwaway worktree** (`.clanker-worktrees/<run-id>`), never the checkout the human/operator invoked `improve-self` from.

The function's own doc comment confirms this is deliberate, not an oversight — it explicitly describes trying a bare `git update-ref` on its own tracking branch and rejecting it because it "left the worktree's checked-out FILES at the pre-merge content", which is why `resyncLocalBranch` exists at all. But that reasoning and fix apply only to the isolated worktree's own consistency (so the *next* improve-self iteration in the same worktree sees the merged content); nothing anywhere in the promote/merge-back path ever considers or resyncs whatever *other* checkout of the same branch invoked the run in the first place.

In every observation today, that other checkout was the exact directory `clanker improve-self ...` was invoked from (`/home/maci/Desktop/clanker`, the primary worktree, with `main` checked out) — the natural, expected way to run the command per its own `--help` and every AGENTS.md example. After the ref moves: `git log`/`git show HEAD` there correctly show the new commit (they read the moved ref), but that checkout's own index and working-tree files were never touched, so `git status`/`git diff HEAD` show the promoted change reverted — exactly the symptom, on every single promotion, unconditionally.
## Resolution (of the investigation, not a code fix)

No code change proposed here. This is a real design gap with a legitimate tradeoff either way — always resyncing the calling checkout could itself be destructive if that checkout has its own uncommitted work in progress (the exact hazard the existing concurrent-sessions runbook is about), so silently doing a `reset --hard` there on every promotion would trade one surprise for a worse one. Whether/how to fix it (a warning printed to the invoking terminal, an opt-in `--sync-caller` flag, or leaving it as an operator responsibility) is a real design decision, not something to make unilaterally mid-investigation.

## Operational guidance (confirmed correct by this investigation)

After invoking `clanker improve-self` from an interactive checkout, always `git status`/`git diff HEAD` before trusting the checkout is clean — if it promoted anything, the calling checkout **will** show the promotion's inverse as a staged (and working-tree) change, unconditionally, every time. This is not tangled/conflicted state and does not need `git stash`/branch-preservation dances: the correct fix is simply

```
git restore --staged <path>                          # if index disagrees with HEAD
git restore --source=HEAD --worktree -- <path>        # sync working tree to the (already correct) HEAD
```

then verify with a real build/test (`zig build test`, exit code checked directly per the AGENTS.md `tail`-masks-exit-code caveat) before pushing. Never `git commit` the stale staged state as-is — it would silently re-delete whatever `improve-self` just promoted and verified, while the commit history claims it landed.

The existing runbook `docs/runbooks/concurrent-agent-sessions-on-one-checkout.md` already describes an adjacent symptom ("unexplained imp- commits and a staged file that undoes them") but frames it as transient, mid-iteration state from a *still-running* respawning loop (`scripts/imp-autorecover-loop/loop.py`) that resolves once the loop goes quiet. All four occurrences here were the process having already fully exited (confirmed via `state/improve.lock` absent and no matching process in `ps`), so "wait for it to finish" does not apply and the state does not self-resolve — the fix above is needed regardless of whether a background loop is also active.
## Fifth occurrence — the hazard fires: stale checkout committed and pushed as a revert

The failure mode the TL;DR warned about (a blind commit of the stale tree re-deleting a verified promotion) actually happened, on origin/main.

Verified from the main checkout's history and the improvements ledger:

- 68726302 (2026-08-19 09:39 +0800) and 6b7e4030 (10:00 +0800) are improve-self promotions to src/doctor.zig: both ids, imp-1787102961990565171 and imp-1787104236888936691, are recorded as status accepted in state/improvements.jsonl (grep over the ledger).
- 124d592e (10:12 +0800, author ywy50) touches only src/doctor.zig, +2/-19, and 'git revert --no-commit 124d592e' on the origin/main tip stages exactly the combined +19/-2 of the two promotions — the commit is the byte-exact inverse of both, i.e. the pre-promotion working-tree copy committed as-is.

Operator's account (reported, not independently reproducible — the checkout was clean again by the time this was traced): doctor.zig was never edited by hand; after the improve worktree merged, the main checkout flagged doctor.zig as an unstaged change, git pull refused because of it, and committing+pushing that 'change' to unblock the pull produced 124d592e.

This matches the confirmed root cause exactly: Worktree.mergeBack's fast-forward moves the shared branch ref and 'git -C <worktree> reset --hard' resyncs only the engine's own throwaway worktree (src/improve/worktree.zig, mergeBack and the reset comment above it), so the invoking checkout's index and working tree stay at pre-promotion content and present the inverse diff.

Impact is no longer 'to be confirmed': two verified, gated, promoted improvements were silently deleted from origin/main by the operator following git's own suggestion for clearing a blocked pull.

Recovery this time: revert of the revert on branch reapply-doctor-improvements (commit 820b61de, plus the CHANGELOG entry the promotions never added), clanker gate all nine gates PASS, merged back via PR. Incident trace: docs/reports/investigations/2026-08-19-stale-checkout-diff-pushed-as-revert.md.

The follow-up stands and is now demonstrated by data loss, not hypothesis: after the fast-forward, mergeBack (or the improve-self CLI epilogue) must resync the invoking checkout's index and working tree to the new HEAD when that checkout is the branch's — or at minimum print the two git restore commands instead of leaving git to suggest committing the inverse diff.