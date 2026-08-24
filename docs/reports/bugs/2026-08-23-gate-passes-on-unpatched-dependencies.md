# Bug — clanker gate passes on unpatched dependencies, so a fresh worktree gates against pristine upstream deps

## TL;DR

- **What failed:** zig-pkg/ is gitignored and per-worktree, and no gate check verifies patches/ is applied, so a fresh worktree builds and gates green against pristine upstream vaxis and zwasm. Verified at b1bd7a6a: apply-patches.sh reports '0 applied' before the first build because the dep trees are not extracted, so patch-then-build leaves the tree unpatched; zig build then exits 0 on it, and only a second apply-patches.sh run reports '4 applied'.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-24. Fixed in 17115abb; verified by clanker gate. New twelfth check dep-patches asserts each patches/*.patch is applied in the zig-pkg/ tree its build.zig.zon .hash pin names, naming scripts/apply-patches.sh on failure. Both directions confirmed with the real binary on one commit: unpatched fails listing all four patches, patched passes with all twelve green. Follow-up: build.zig additionally refuses to configure against an unpatched dependency tree (requireDependencyPatches: one marker line per patch, checked before any compile; failure names scripts/apply-patches.sh), and CI and scripts/verify.sh run zig build --fetch=all then apply-patches.sh before any compile step, since extraction must precede patching. Verified 2026-08-25: missing ss3 marker makes zig build exit 1 naming the patch; patched tree stays green.

## Status

Resolved on 2026-08-24. Fixed in 17115abb; verified by clanker gate. New twelfth check dep-patches asserts each patches/*.patch is applied in the zig-pkg/ tree its build.zig.zon .hash pin names, naming scripts/apply-patches.sh on failure. Both directions confirmed with the real binary on one commit: unpatched fails listing all four patches, patched passes with all twelve green. Follow-up: build.zig additionally refuses to configure against an unpatched dependency tree (requireDependencyPatches: one marker line per patch, checked before any compile; failure names scripts/apply-patches.sh), and CI and scripts/verify.sh run zig build --fetch=all then apply-patches.sh before any compile step, since extraction must precede patching. Verified 2026-08-25: missing ss3 marker makes zig build exit 1 naming the patch; patched tree stays green.

## Symptom and impact

`clanker gate` runs eleven checks — build, test, tools, fmt, lint,
provider-kind, test-root-coverage, js-suite-coverage, sandbox-abi,
tools-ts-toolchain, release-contract. None of them asks whether
`scripts/apply-patches.sh` has been run.

`.gitignore` lists `zig-pkg/`, so the dependency cache is per-worktree and a
`git worktree add` starts with none. `zig build` extracts pristine upstream
tarballs, and nothing re-applies the four trees under `patches/`. The gate then
passes on that tree without a word.

The repository rules make every agent session work in a hand-made worktree, so
this is the default state for agent work, not an edge case.

Two coverage consequences, both silent:

- `sixel_supported` in `src/tui/mascot.zig` compiles the sixel path out when
  the dependency lacks `patches/vaxis-sixel-graphics.patch`, so a green run in
  an unpatched worktree covers strictly less code than the same commit in a
  patched checkout. A passing mascot test there is not "sixel verified".
- `patches/vaxis-winch-self-pipe.patch` is the fix `pty_resize_test` exists to
  pin. Without it the REPL services SIGWINCH inside the signal handler. The
  gate does not run `zig build e2e`, so nothing in the gate notices.

## Reproduction

Verified first-hand on 2026-08-23 UTC in a fresh worktree at `b1bd7a6a`.

The ordering trap comes first. On a worktree that has never been built,
`scripts/apply-patches.sh` cannot find anything to patch and says so, then
exits reporting success:

```
apply-patches: vaxis-sixel-graphics: no vaxis-0.6.0-* tree under <worktree>/zig-pkg ~/.cache/zig;  skipping (a zig build must extract dependencies first)
... same for vaxis-ss3-keypad-enter, vaxis-winch-self-pipe, zwasm-lazy-mem-cksum
apply-patches: 0 applied, 0 already up to date
```

So the intuitive order — patch the tree, then build it — leaves the tree
unpatched. `zig build` immediately after that then completes normally:

```
=== EXIT 0 ===
```

Only a second run, after the build has extracted the dependency trees, does the
work:

```
apply-patches: 4 applied, 0 already up to date
```

Independently, a parallel session gated a fresh worktree at `1d8a2ae9` with all
eleven checks passing and `zig build e2e` at 37/38, ran `apply-patches.sh` (4
applied), and got 38/38 on the same commit with no source change — recorded in
`docs/reports/investigations/2026-08-23-pty-resize-journey-fails-in-an-unpatched-worktree.md`.
That investigation closed as "no code defect" on the question it asked, which
was why one e2e journey failed. The gate-coverage question is this record.

## Root cause

`patches/` is applied by a script nothing calls. `build.zig` does not depend on
it, and `src/gate/checks.zig` has no check for it, so the applied state of the
dependency cache is an untracked precondition that the gate reports nothing
about either way.

The four patches are load-bearing local fixes to pinned upstream deps, not
optional extras: `patches/README.md` says of the winch one that "without the
vaxis SIGWINCH self-pipe patch, resizing the terminal in `clanker repl` aborts
the process".

## Resolution

Fixed in 17115abb as the twelfth check, `dep-patches`, in
`src/gate/checks.zig` beside `sandbox-abi` and `test-root-coverage`. It runs
last in `verifyGates`, after the build, because on a tree that has never been
built there is nothing extracted to patch and a check that ran first could
only ever report the ordering trap. The failure names
`scripts/apply-patches.sh`.

Which tree to look in is read from `build.zig.zon`: the `.hash` pin is
verbatim the directory name under `zig-pkg/` the package is extracted into, so
the check follows a version bump on its own and cannot mistake a stale
`zwasm-2.4.1-*` tree left behind by an older pin for the current one. The
patch's package comes from its file name (`vaxis-winch-self-pipe.patch` is a
vaxis patch), the same convention `apply-patches.sh` and `patches/README.md`
already use.

Not by the marker `apply-patches.sh` greps for, as this record suggested: that
is a reverse dry-run of `patch`, which would make the gate report on a tool
that need not be installed. Instead each patch yields, per file it touches,
its longest contiguous run of added lines, rejoined exactly as the patched
file will carry them (indentation and interior blank lines included), and the
check is a plain substring search.

A single longest added LINE was the first version and was wrong.
`vaxis-ss3-keypad-enter.patch`'s longest addition is
`const expected_event: Event = .{ .key_press = expected_key };`, a line every
other parser test in that file already has, so the check reported that patch
applied on a pristine tree — this record's own false-clean failure, reproduced
inside its fix. The run-based marker (13 lines for that patch) reports it
correctly. A whole added block can be duplicated in principle too, but not by
accident.

Not taken: the `build.zig` refusal. It is strictly earlier, but it would make
the FIRST build of every fresh clone fail, and that first build is what
extracts the dependencies there is nothing to patch without. The trap would
move rather than close.

Not taken either: making `zig build` apply the patches itself. Nothing in the
check applies a patch; it only reports.

## Verification

Both directions, with the real binary, on one commit in one fresh worktree.

Unpatched (`git worktree add` then `zig build`, nothing else): eleven checks
PASS and `dep-patches` FAILs, listing all four patches and every file each one
is missing from, and naming `scripts/apply-patches.sh` and the `zig build`
that has to come first.

Then `scripts/apply-patches.sh` (4 applied) and `zig build`, same commit, no
source change: all twelve PASS. A check that fails on both states is
indistinguishable from one that fails on neither until you look, and the
line-marker version of this check did in fact pass on a pristine tree for one
of the four patches until the control run showed it.

Unit level, in `src/gate/checks.zig`: `depPatchesGate` is driven over a
synthetic dependency tree in a tmpdir through all three states — pristine
(fails, names the script), patched (passes), and never extracted (fails,
distinctly) — plus pure tests for the marker extraction, the `.hash` lookup
(a package name that is only a prefix of a pinned one must not match) and the
`-p1` path strip. There is deliberately NO "passes on the live checkout" test
of the kind `sandboxAbiGate` has: the suite itself runs in worktrees whose
patched state is exactly what is in question.

## Follow-up

Whatever gates the patches should cover `tools/ts/dist/` too. AGENTS.md records
the same shape there: "clanker gate never rebuilds tools/ts/, so a .ts edit
without npm run build:all ships stale tools/ts/dist/*.wasm silently", with
`tools/ts/verify.sh` as the manual check. Two untracked build preconditions,
one gate that speaks to neither.

Still open as of 17115abb: `dep-patches` speaks only about `patches/`. The
`tools/ts/dist/` half needs a rebuild-and-compare, not a substring search, so
it is a different check rather than another entry in this one.

## References

- Investigation: [2026-08-23-pty-resize-journey-fails-in-an-unpatched-worktree.md](../investigations/2026-08-23-pty-resize-journey-fails-in-an-unpatched-worktree.md)
- Earlier record of the same root cause, scoped to one journey: [2026-08-22-pty-e2e-fails-in-a-worktree.md](../investigations/2026-08-22-pty-e2e-fails-in-a-worktree.md)
- Code: `src/gate/checks.zig` (`depPatchesGate`), `src/cli.zig`
  (`verifyGates`), `build.zig`,
  `scripts/apply-patches.sh`, `patches/README.md`
- Affected by the compiled-out path: `src/tui/mascot.zig` (`sixel_supported`)
