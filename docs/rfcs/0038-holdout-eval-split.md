# RFC 0038 — Should improve-self grade promotions against a held-out eval suite the proposer cannot see?

## Status

Draft — opened 2026-09-29.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

improve-self promotes a patch when the visible evals in evals/*.task.json pass. The proposer can read those cases, may add new ones (surface_rules, src/improve/engine.zig), and receives the failing eval output as feedback ('Fix exactly that and re-propose', engine.zig capability-eval retry). Nothing measures whether an improvement holds on cases the loop never saw. The AIDE2 report (weco.ai, 'first evidence of recursive self-improvement') selects on private scores the inner agent never sees, and treats reward hacking as the failure to design against. Decide whether clanker gets an equivalent split, and where the hidden cases live.

**Decision to make.** Which mechanism, if any, grades an improve-self promotion on cases the proposing model cannot read and receives no output from?

**Why now.** The loop is the product's central claim, and its only acceptance signal on capability is a suite the proposer reads, extends and is fed failures from. A patch that special-cases the visible cases passes as well as one that fixes the behavior. The ledger records the gate outcome, so the gap is invisible after the fact.

**Drivers.**

- The hidden cases must be unreadable through every path the proposer has: repo tree, file requests, git history, pinned context, feedback text.
- No new dependency. Cases reuse the existing `*.task.json` format and the `clanker eval --tasks` runner.
- A fresh checkout must still run the loop.
- The decision runs from the binary on disk and stays outside what a later pass can rewrite (`src/improve/` and `src/gate/checks.zig` rules already cover this).
- Cost per promotion stays near today's: the eval phase is already most of the gate time (`engine.zig` notes ~334s of ~368s).

**Out of scope.** Per-proposal token or cost budgets (no cost is recorded per improvement today, so there is no baseline), outlier removal on scores (evals are pass/fail), prompt compression, and search-policy changes from the AIDE2 report.

## Current state

`src/improve/engine.zig` runs the staged binary's `eval --tasks` over `evals/` after build, unit tests and the inert check. On failure it parses the FAIL lines, retries only those cases, and on a second failure hands the output tail back to the model. `surface_rules` lets the proposer create a new `evals/<name>.task.json` and forbids editing or deleting an existing one. Evals are binary per case. The visible suite is part of the tree the proposer reads and part of the context it pins.

Files that would change under a split: `src/config.zig` (`Improve`), `src/improve/engine.zig`, `src/gate/checks.zig` and the `gate_invariants` table, `docs/configuration.md`, `CHANGELOG.md`, tests.

## Options considered

### Option A — `improve.holdout_dir`, a directory outside the repo tree

- **What it is:** a config field naming a directory of `*.task.json`. After the visible evals pass, the promote step runs the staged binary against that directory. Any failure rejects the proposal, and the feedback to the model says only that a held-out check failed: no case name, no output.
- **Maturity:** not applicable; uses the existing case format and runner.
- **How it would fit:** one config field, one extra `eval --tasks` invocation pointed at another directory, one refusal path, one `gate_invariants` entry so the check cannot be dropped. The directory is not in `surface_rules`, not copied into staging as a readable file, not in pinned context.
- **Pros:** closes the visible-suite leak directly. No new case format. Reversible by unsetting the field.
- **Cons:** the operator authors and maintains the hidden cases. A case that leaks into the visible suite stops being hidden. Whether the proposer's file requests can reach the directory is unverified; the path must be checked against them.
- **Cost to adopt:** roughly one engine change plus tests and docs. Recurring cost is the extra eval run per promotion and the upkeep of the cases.
- **Cost to leave:** delete the field and the invocation.
- **Evidence:** engine.zig capability-eval retry and `surface_rules` (read in this session). The AIDE2 report describes selection on private scores (weco.ai blog, read in this session; the underlying paper was not opened).

### Option B — flag some in-repo evals as held out

- **What it is:** a `"holdout": true` field on selected `evals/*.task.json`. The engine hides those cases from context and feedback but they stay in the tree.
- **How it would fit:** filter in the engine's context builder and feedback path.
- **Pros:** no config, no second directory, cases version with the code.
- **Cons:** the proposer can still read the files, and git history keeps them. The split rests on the model not looking, which is the weakness being fixed. Only stops accidental tuning.
- **Cost to adopt:** small. **Cost to leave:** remove the flag.
- **Evidence:** none beyond the engine read. Unverified that file requests would skip flagged files.

### Option C — status quo

- **What it is:** keep the visible suite as the only capability gate.
- **Pros:** zero work; the loop already rejects most inert and test-only patches.
- **Cons:** a patch tuned to the visible cases passes. No signal exists on whether promotions generalize.
- **Cost to adopt:** zero now. Later cost is unmeasured regressions that the gate never saw.
- **Evidence:** `src/improve/inert_check.zig` covers the do-nothing shape only, not the tuned-to-the-test shape.

### Option D — hidden cases written fresh per promotion

- **What it is:** at promotion time, a separate model call (a different provider from the proposer) writes one or more `*.task.json` cases from the staged diff, runs them, and discards them. There is no fixed set to overfit.
- **Pros:** nothing to leak or maintain. Adapts to what the patch touched.
- **Cons:** nondeterministic. A wrong case rejects a good patch or passes a bad one. Costs a model call per promotion. The judge is itself a model output, so its cases need the same fencing as any untrusted text.
- **Cost to adopt:** larger than A. **Cost to leave:** delete the call.
- **Evidence:** none. Unverified idea; a spike would be needed.

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** one config field and an engine change. The operator must write a first set of hidden cases before it means anything.
- **If B:** ships fast and reads as protection it does not provide.
- **If D:** needs a spike before a decision.
- **If status quo:** nothing changes.

### Medium term (3–12 months)

- **If A:** the hidden set needs rotation as cases leak or the product changes. The ledger can record hidden pass and fail per promotion, which gives the first generalization signal.
- **If B:** the model eventually reads the flagged files and the split erodes.
- **If D:** flaky rejections wear down trust in the gate.
- **If status quo:** overfit promotions accumulate with nothing to detect them.

### Long term (12+ months)

- **If A:** can grow into a scored hidden suite if evals gain a scalar.
- **If D:** could complement A as a second layer.
- **If status quo:** the loop's improvement claim has no held-out evidence behind it.

## Recommendation

**Recommended option:** A

**Confidence:** 6/10

**Why this confidence.** The mechanism is small and reuses existing pieces. Confidence is capped by three things not yet checked: whether the proposer's file requests or staging copy can reach an external directory, whether the hidden set can be authored at a useful size, and how often visible-suite overfitting actually occurs in `state/improvements.jsonl`. A ledger review showing promoted patches that later regressed would raise it. A finding that file requests can read any path on disk would force a rethink of where the directory lives.

**Rationale.** Closes the visible-suite leak by construction; capped by unverified reachability of the directory and unmeasured overfit frequency.

**Reversibility.** High. Unsetting the field restores today's behavior. No data format changes.

## Open questions

- Can `file_requests` or staging reach `improve.holdout_dir`? Answer by reading the file-request path in `src/improve/engine.zig` and testing with a marker file.
- When the field is unset, does the loop run as today or refuse to promote? The operator's answer was "set it", which I read as shipping with a default path already set. That reading is not confirmed, and a default inside the checkout (for example under `state/`) may itself be reachable by the proposer. Confirm which was meant.
- Who authors the first hidden cases, and how many make the check meaningful?

## Next steps / action items

- [ ] Resolve the two open questions above.
- [ ] Review `state/improvements.jsonl` for promoted patches that later regressed.
- [ ] Set status to `discussion` once the operator has read this.
- [ ] Write the ADR once the decision is made.

## References

- `src/improve/engine.zig`: `surface_rules`, capability-eval retry and feedback.
- `src/improve/inert_check.zig`: the existing "does nothing" gate.
- https://www.weco.ai/blog/first-evidence-of-recursive-self-improvement: private-score selection in AIDE2.
