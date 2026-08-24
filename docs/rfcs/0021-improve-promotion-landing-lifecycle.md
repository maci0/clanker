# RFC 0021 — How improve-self promotions reach origin and the invoking checkout

## Status

Discussion — 2026-08-19. Drafted 2026-08-19 at operator request after promotions were lost via 124d592e; open for the operator's comment — the phase-2 trigger (open question 2) is the main thing to settle.

## Overview

Worktree.mergeBack lands a promotion as a local update-ref on refs/heads/main: src/improve/ contains no git fetch, no reference to origin, and no git push (checked by grep over src/improve/*.zig, 2026-08-19). Three operational consequences are now on record: the invoking checkout is left showing the promotion's inverse diff, which an operator committed and pushed as 124d592e, deleting two promotions (bug 2026-08-19-improve-self-merge-leaves-worktree-reverted, reopened, fifth occurrence); promotions sit unpushed on local main until the operator notices; and because the worktree bases on the local main tip without fetching, a stale local main produces non-fast-forward push rejections. The decision: what lifecycle should a promotion follow between the engine's worktree, the invoking checkout, and origin.

**Decision to make.** Which landing lifecycle do we adopt for an improve-self promotion: local-only as today, local with checkout resync and fetch-fresh base, a full origin branch → push → PR → merge flow, or a dedicated landing branch that never touches main?

**Why now.** The local-only design destroyed work on 2026-08-19: the invoking checkout's stale inverse diff was committed and pushed as 124d592e, deleting two gated promotions from origin/main (fifth recorded occurrence of the stale-checkout symptom; first with data loss). The operator's expectation is explicit: worktree from latest origin default branch → validate → push/merge to remote.

**Drivers.** Promotions must never be silently lost or reverted; the invoking checkout must end a run clean or with an accurate picture; the engine must stay usable offline (gates run locally); credential surface must stay deliberate — today the engine needs no push rights and improve-self can rewrite most of the tree, so granting network write access is a real trust decision; the operator merge workflow for this repo is branch → PR → merge.

**Out of scope.** Multi-instance replication of state (RFC 0019 / RFC 0001 territory); what the gates verify; scheduling of improve runs (ADR 0008).

## Current state

All in src/improve/worktree.zig and engine.zig, verified 2026-08-19 by reading mergeBack and grepping src/improve/ (zero hits for fetch, origin, or a real git push):

1. Worktree.createOrReuse bases the engine's private worktree on the local branch tip — no fetch, so a local main behind origin seeds work on a stale base.
2. Worktree.mergeBack lands a promotion by compare-and-swap git update-ref refs/heads/main (retried on concurrent movement), then git -C <worktree> reset --hard — deliberately pinned to the engine's own throwaway worktree so it can never reset the operator's checkout.
3. Nothing pushes. Nothing resyncs the invoking checkout, whose index and working tree keep pre-promotion bytes and present the promotion's inverse diff as local changes; git pull then refuses.

The workaround in place of a decision is operational guidance (AGENTS.md src/improve bullet, the reopened bug report): git restore --staged + git restore --source=HEAD --worktree, never commit the diff, push manually.

## Options considered

### Option A — local landing, made honest: fetch-fresh base, checkout resync, push reminder

- **What it is:** keep promotions landing on local main, but fix the three gaps: fetch origin before basing the worktree (base on origin/<default> when reachable, local tip offline), resync the invoking checkout's index and working tree to the new HEAD after mergeBack's fast-forward when that checkout sits on the merged branch and was clean, and end the run with an explicit epilogue naming how many commits await push.
- **Maturity:** all in-tree; git subcommands the engine already shells out to.
- **How it would fit:** src/improve/worktree.zig (createOrReuse fetch; mergeBack gains a resync of the invoking checkout, guarded on that checkout being clean and on the merged branch — a dirty checkout gets the two restore commands printed instead of a reset) and the improve-self CLI epilogue in engine.zig/cli.zig. No new credentials, no network write.
- **Pros:** eliminates the data-loss path (the inverse diff never appears on a clean checkout); kills the stale-base push rejections; offline behavior unchanged; no new trust granted to the engine.
- **Cons:** promotions still wait for a manual push; touching the operator's checkout at all is the hazard mergeBack's reset was deliberately pinned away from — the clean-and-on-branch guard is the safety argument and must be tested; fetch adds a network touch (fail-open) to run start.
- **Cost to adopt:** small, well-localized; tests for the guard.
- **Cost to leave:** trivial — remove the resync and fetch.
- **Evidence:** bug 2026-08-19-improve-self-merge-leaves-worktree-reverted (five occurrences, mechanism confirmed); investigation 2026-08-19-stale-checkout-diff-pushed-as-revert (data loss); TODO-board blocked-push entry of 2026-08-18 (stale base, push rejected — operator account, unverified beyond the note).

### Option B — full origin lifecycle: fetch → branch from origin default → push → PR → merge

- **What it is:** the operator's stated expectation and this repo's own agent workflow, done by the engine: base the worktree on the fetched origin default branch, and on a green gate push the branch, open a PR, and merge it, config-gated (improve.landing = "local" | "push" | "pr", defaulting to today's local).
- **Maturity:** git push is git; PR open/merge needs a forge client — gh subprocess or the forge HTTP API, neither in-tree today.
- **How it would fit:** worktree.zig/engine.zig plus a forge credential the engine can use; mergeBack's local update-ref becomes the offline fallback. The invoking checkout stops being the landing site — the operator pulls like for any other merged PR. ck_exec's allowlist does not include push today; the engine is native, but every trust question raised on the sandbox side applies to the engine holding push rights over the repo it rewrites.
- **Pros:** promotions can no longer sit unpushed or revert the checkout — main only moves via origin, which the operator already pulls; matches the repository rule every other agent follows; remote CI sees each promotion.
- **Cons:** a self-improving loop with push+merge rights on its own repository is a materially larger trust grant than local-only, and its failure mode is remote and shared, not local; needs credential plumbing, offline fallback, and forge-API error handling; per-promotion PRs are noisy for an --iters N run unless batched.
- **Cost to adopt:** the largest of the four; new operational surface (auth, rate limits, merge conflicts on the remote).
- **Cost to leave:** config flip back to local; the code stays as dead weight.
- **Evidence:** operator's stated expected lifecycle (2026-08-19 session, verbatim: worktree → latest origin default → validate → commit/push/merge); .agents/agent-rules/repo-rules-merge-workflow.md — the same lifecycle imposed on human-driven agents in this checkout.

### Option C — status quo: local-only landing, guidance in AGENTS.md

- **What it is:** keep doing what we do today — local update-ref, no fetch, no push, no resync — and rely on the documented restore commands and manual pushes.
- **Pros:** zero code risk; the engine keeps zero network write surface; mergeBack's never-touch-the-operator's-checkout rule stays absolute.
- **Cons:** the guidance already failed once with data loss — it depends on the operator recognizing the inverse diff every single promotion, under git actively suggesting the wrong action (commit it); stale-base push rejections remain; unpushed promotions remain invisible until a pull collides.
- **Cost to adopt:** zero now; the recurring cost is this incident class repeating, and the next one may not be caught by a session that knows the bug.
- **Evidence:** five occurrences in bug 2026-08-19-improve-self-merge-leaves-worktree-reverted; occurrence five lost promoted work despite the report existing since the first four.

### Option D — out-of-the-box: promotions land on a dedicated branch and a board card, never on main

- **What it is:** mergeBack fast-forwards a persistent clanker/landed branch instead of main and files a board card (the kanban tools the engine already has) per promotion; main — local and remote — moves only when the operator merges that branch through the normal PR flow.
- **Maturity:** everything used is already in-tree: update-ref CAS on an arbitrary ref (worktree.zig already parameterizes the branch), kanban_* tools, the existing PR workflow.
- **How it would fit:** change the target ref in the promotion path; add the card action; the invoking checkout is never behind by construction, so no resync is needed and the inverse-diff class disappears without ever touching the operator's tree.
- **Pros:** strongest safety story of the four — the engine writes only refs nothing else has checked out; batching N promotions into one reviewed PR is natural; offline-clean.
- **Cons:** promotions stop being immediately live in the checkout that requested them — the operator (or a scheduled run) must merge before the improved binary is what clanker improve-self builds next, which weakens the self-improvement feedback loop the engine exists for; two long-lived histories to keep from diverging.
- **Cost to adopt:** moderate; mostly re-pointing the landing ref and the operator workflow change.
- **Cost to leave:** merge clanker/landed once and re-point back to main.
- **Evidence:** worktree.zig's CAS helper already takes the branch name (src/improve/worktree.zig, casUpdateRef path); kanban card flow per CLAUDE.md board section.

## Implications by horizon

The options differ most in the short term (whether the data-loss path closes now) and in the long term (who holds push rights); medium term they converge on "operator pulls, engine lands" in different orders.

### Short term (this release / 0–3 months)

- **If A:** inverse-diff incidents stop for clean checkouts; pushes stay manual but announced. Smallest diff that closes the loss path.
- **If B:** loss path also closes, but behind credential plumbing and forge integration that will take longer than the incident class keeps recurring.
- **If D:** loss path closes by construction; operator workflow changes immediately (merge before the improvement is live).
- **If status quo:** the next promotion recreates the inverse diff on the operator's checkout the same day.

### Medium term (3–12 months)

- **If A:** manual push remains the one human step; acceptable while one operator runs one checkout, strained if improve runs are scheduled (ADR 0008 cron) while nobody is watching.
- **If B:** promotions flow to origin unattended; remote CI becomes the real gate echo; forge outages become improve-run failures to handle.
- **If D:** the landed branch accumulates between merges; a scheduled merge cadence or card discipline is needed so the self-improvement loop keeps eating its own output.
- **If status quo:** guidance decays as sessions and operators change; the bug report grows occurrences.

### Long term (12+ months)

- **If A:** compatible with adding B or D later — nothing in A is thrown away (fetch-fresh base and the epilogue are wanted under every option).
- **If B:** the engine permanently holds repo write credentials; every future trust review of improve-self includes the forge.
- **If D:** cleanest permanent trust boundary, but only if the merge cadence became routine; otherwise it quietly becomes a fork.
- **If status quo:** local-only landing hard-wires single-operator, single-checkout operation.

## Recommendation

**Recommended option:** Phased: Option A now — fetch-fresh base, guarded checkout resync, push-pending epilogue — and revisit B or D the moment improve runs become scheduled/unattended, because manual push is A's one human step and it only works while a human is in the loop.

**Confidence:** 7/10

**Why this confidence.** Resting on a confirmed mechanism (five recorded occurrences, root cause read in worktree.zig) and on A's pieces being wanted under every other option. It would rise to 8-9 with a test proving the resync guard can never fire on a dirty or differently-checked-out tree. It sinks if the guard turns out not to be reliably decidable (e.g. another session mutates the checkout between the fast-forward and the resync — the checkout is shared, see the concurrent-sessions runbook), in which case D becomes the recommendation.

**Rationale.** A is the smallest change that closes the demonstrated data-loss path, and every piece of it (fetch-fresh base, epilogue) is still wanted under B and D, so nothing is wasted by phasing. It beats B as the immediate step because B's cost is credential and forge plumbing plus a real expansion of what a self-rewriting engine may touch — a trust decision that deserves its own ADR when actually needed, not as a side effect of a bug fix. It beats D because D weakens the loop's feedback (promotions stop being live in the invoking checkout) for a safety property A already achieves on clean checkouts. The residual risk in A is the resync guard: touching the operator's checkout is exactly what mergeBack's reset was pinned away from, so the clean-and-on-branch guard needs its own tests before this ships.

**Reversibility.** A is fully reversible — remove the fetch and the resync and the engine is byte-for-byte today's behavior; no data format, API, or dependency changes. The only one-way door in the option space is B's credential grant once relied upon, and A deliberately does not open it.

## Open questions

1. Can the resync guard be made race-free on a shared checkout (concurrent sessions runbook scenario: another session stages hunks between fast-forward and resync)? Answerable by a test against two writers; sinks A toward D if no.
2. When improve runs go scheduled/unattended (system cron calling clanker schedule run-due), does the operator want B (engine pushes) or D (landing branch merged by a human/scheduled PR)? Operator's call; this is the phase-2 trigger named in the recommendation.
3. Should the fetch-fresh base refuse to run when origin is ahead and unreachable-merge (local main diverged), instead of silently basing on the stale tip? Answerable by deciding what the offline contract is.

## Next steps / action items

- [ ] Operator comment on the recommendation, especially open question 2 (the phase-2 trigger).
- [ ] Test-first spike for the resync guard: two concurrent writers on one checkout, prove the guard never resets a tree with any local modification or a different branch checked out (settles open question 1).
- [ ] If accepted: implement A in src/improve/worktree.zig + engine.zig behind the existing gate suite; the guard test lands with it.
- [ ] Write the ADR once decided; supersede nothing — this is the first decision on the landing lifecycle.

## References

- Bug (reopened, five occurrences, root cause): docs/reports/bugs/2026-08-19-improve-self-merge-leaves-worktree-reverted.md
- Incident with data loss: docs/reports/investigations/2026-08-19-stale-checkout-diff-pushed-as-revert.md — shows 124d592e is the byte-exact inverse of two promotions, committed from the stale checkout.
- Runbook: docs/runbooks/concurrent-agent-sessions-on-one-checkout.md — the shared-checkout race the resync guard must survive.
- RFC 0001 (workspace/worktree hierarchy) — why runs isolate in worktrees; does not decide landing.
- ADR 0008 (scheduler is cron-driven) — the unattended-runs future that triggers phase 2.
- src/improve/worktree.zig mergeBack + the reset-pinned-to-worktree comment — current mechanism, read 2026-08-19; grep of src/improve/ for fetch/origin/push (zero hits) — supports the no-fetch/no-push claims.
