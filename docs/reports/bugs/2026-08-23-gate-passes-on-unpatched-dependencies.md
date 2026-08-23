# Bug — clanker gate passes on unpatched dependencies, so a fresh worktree gates against pristine upstream deps

## TL;DR

- **What failed:** zig-pkg/ is gitignored and per-worktree, and no gate check verifies patches/ is applied, so a fresh worktree builds and gates green against pristine upstream vaxis and zwasm. Verified at b1bd7a6a: apply-patches.sh reports '0 applied' before the first build because the dep trees are not extracted, so patch-then-build leaves the tree unpatched; zig build then exits 0 on it, and only a second apply-patches.sh run reports '4 applied'.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

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

Open. Not fixed here: this record is the finding, and the fix is a gate check,
which is a code change that belongs with its own tests rather than folded into
a docs pass.

The shape that fits the existing design is a twelfth check in
`src/gate/checks.zig` beside `sandbox-abi` and `test-root-coverage` — both of
which exist for exactly this class of problem, an invariant a green suite
cannot speak to. It would assert each `patches/*.patch` is applied in the
resolved dependency tree, by the same marker `apply-patches.sh` already greps
for when it decides "already up to date". Failure should name
`scripts/apply-patches.sh` in the message, the way the `ReplStoppedReadingTty`
e2e branch already does.

A cheaper variant worth considering instead: have `build.zig` fail the build
outright on an unpatched dependency, since no target in this repo is meant to
be built against pristine vaxis. That closes the ordering trap too, which a
gate check alone does not — the gate runs a build, so a build-time refusal is
strictly earlier.

Not proposed: making `zig build` apply the patches itself. Silently mutating a
dependency cache as a build side effect trades a visible failure for an
invisible one.

## Verification

A fix is verified when `clanker gate` fails on a freshly built worktree whose
`patches/` have not been applied, and names `scripts/apply-patches.sh` in the
failure. Both halves matter: the existing e2e failure was read as a REPL
regression by two separate sessions precisely because its message did not name
the check.

Control needed on the other side, or the check can pass without running: gate
the same commit with the patches applied and confirm it stays green. A check
that fails on both states is indistinguishable from one that fails on neither
until you look.

## Follow-up

Whatever gates the patches should cover `tools/ts/dist/` too. AGENTS.md records
the same shape there: "clanker gate never rebuilds tools/ts/, so a .ts edit
without npm run build:all ships stale tools/ts/dist/*.wasm silently", with
`tools/ts/verify.sh` as the manual check. Two untracked build preconditions,
one gate that speaks to neither.

## References

- Investigation: [2026-08-23-pty-resize-journey-fails-in-an-unpatched-worktree.md](../investigations/2026-08-23-pty-resize-journey-fails-in-an-unpatched-worktree.md)
- Earlier record of the same root cause, scoped to one journey: [2026-08-22-pty-e2e-fails-in-a-worktree.md](../investigations/2026-08-22-pty-e2e-fails-in-a-worktree.md)
- Code: `src/gate/checks.zig` (the eleven checks), `build.zig`,
  `scripts/apply-patches.sh`, `patches/README.md`
- Affected by the compiled-out path: `src/tui/mascot.zig` (`sixel_supported`)
