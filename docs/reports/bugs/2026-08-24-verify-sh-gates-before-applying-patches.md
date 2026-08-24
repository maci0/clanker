# Bug — verify.sh runs clanker gate before apply-patches.sh, so a fresh worktree always fails dep-patches

## TL;DR

- **What failed:** scripts/verify.sh called the gate at :57 and scripts/apply-patches.sh at :60, so on any fresh worktree the twelfth gate check dep-patches failed on the line immediately before the one that would have fixed it, and the gate's own remedy message named that next line
- **Impact:** `scripts/verify.sh` — the documented pre-push check — could not pass on a fresh worktree or a newly made agent worktree. Reproduced.
- **Resolution:** Resolved on 2026-08-24. reordered scripts/verify.sh so zig build and apply-patches.sh precede clanker gate; verified pristine-to-green in one worktree

## Status

Resolved on 2026-08-24. reordered scripts/verify.sh so zig build and apply-patches.sh precede clanker gate; verified pristine-to-green in one worktree

## Blocked on

## Symptom and impact

`scripts/verify.sh` is the local stand-in for CI and what contributors are told
to run before pushing. Its steps ran in this order:

```
step "zig build + clanker gate (CI: Run deterministic gate)"
zig build || status=1                      # :56
./zig-out/bin/clanker gate || status=1     # :57

step "dependency patches (patches/*.patch)"
./scripts/apply-patches.sh || status=1     # :60
```

`zig build` extracts pristine upstream tarballs into `zig-pkg/`, which is
gitignored and therefore per-worktree. The gate's twelfth check `dep-patches`
fails while those trees are unpatched. So on any tree where the patches were
not already applied — a fresh clone, and every hand-made `git worktree add`
worktree, which is the mandated flow for agent sessions here — `verify.sh`
failed at `:57` on the line immediately before the one that would have fixed
it. The gate's own failure text names the remedy: "Run `zig build` (to extract
the dependencies) and then `scripts/apply-patches.sh`" — which is exactly
`:60`, one line later.

The effect is a guaranteed false red in the check whose entire purpose is to
tell a contributor their tree is good. A false red in a pre-push gate is
corrosive in a specific way: the cheapest way to make it stop is to learn to
disregard it.

## Reproduction

1. `git worktree add -b probe <dir> origin/main` (or any fresh clone).
2. `zig build`
3. `./zig-out/bin/clanker gate`

Observed at `ea59ba3a`: `dep-patches: FAIL`, listing all four patches as not
applied across `vaxis-0.6.0-*` and `zwasm-2.5.0-*`, and `error: one or more
gates failed`. Step 3 is what `verify.sh:57` runs, and `verify.sh:60` is what
makes it pass.

## Root cause

Step ordering only. `dep-patches` was added to the gate on 2026-08-24; before
it existed, gating before applying patches was harmless, so the ordering in
`verify.sh` was correct when written and became wrong when the check landed.
Nothing in `verify.sh` referenced `dep-patches`, so there was no signal
connecting the two.

Not caused by making `apply-patches.sh` exit non-zero on a missing tree the
same day: in `verify.sh` the script runs after `zig build`, so it always finds
its trees and exits 0 either way. That change is unrelated to this ordering.

## Resolution

Reordered so the patch step precedes the gate: `zig build` and
`./scripts/apply-patches.sh` under the "dependency patches" step, then
`clanker gate` as its own step. The comment above it states why the order is
load-bearing, so the next person to tidy the file does not undo it.

## Verification

Both directions, in one worktree at `ea59ba3a`:

- **Before:** fresh worktree, `zig build` then `clanker gate` — `dep-patches:
  FAIL` with all four patches listed.
- **After:** `rm -rf zig-pkg` to restore pristine dependencies, then the new
  order — `apply-patches: 4 applied, 0 already up to date`, then **all twelve
  gate checks PASS**.

`bash -n scripts/verify.sh` is clean. `shellcheck` is not installed on this
machine, which `verify.sh` itself notes is expected and why the check is in CI
rather than the gate.

## Follow-up

Found by a peer session reading the source and handed over as an explicitly
unverified claim; reproduced here before acting on it, which is the right
handling for a claim that arrives with a conclusion attached.

The general shape is worth noting because it has now happened twice in one
day: adding a gate check does not update the scripts that run the gate. Both
`dep-patches` (this record) and the `release-contract` misconception
([investigation](../investigations/2026-08-24-release-contract-never-reads-the-diff.md))
were cases where what a gate actually enforces and what the surrounding
tooling and docs assumed had drifted apart.

## References

- Code: `scripts/verify.sh`, `scripts/apply-patches.sh`, `src/gate/checks.zig`
  (`depPatchesGate`)
- Related bug: [apply-patches.sh exits 0 having applied nothing](2026-08-24-apply-patches-exits-0-having-applied-nothing.md)
  — same script, adjacent failure, fixed in #400
- Investigation: [release-contract never reads the diff](../investigations/2026-08-24-release-contract-never-reads-the-diff.md)
