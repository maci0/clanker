# Investigation — The two pty e2e tests fail in any git worktree and pass in the main checkout

## TL;DR

- **Question:** zig build e2e fails pty_resize_test and pty_preview_test in a PRISTINE worktree at the same commit that passes in the main checkout. Both die at pty.answerQueries, the terminal-capability handshake, so the repl's queries never reach the test. Every agent session works in a worktree per the repository rules, so e2e is effectively unrunnable there. Root cause not yet found.
- **Finding:** Resolved on 2026-08-23. Same defect as 2026-08-22-pty-e2e-capability-queries-unanswered.md: the split was patched-versus-pristine, not main-checkout-versus-worktree, because patches/ lands in gitignored zig-pkg/. Fixed in tests/e2e/pty.zig answerQueries. Checked with zig build e2e: pty_preview_test passes in a pristine worktree. pty_resize_test still fails on a pristine tree by design and now fails loudly instead of hanging.
- **Resolution:** Resolved on 2026-08-23. Same defect as 2026-08-22-pty-e2e-capability-queries-unanswered.md: the split was patched-versus-pristine, not main-checkout-versus-worktree, because patches/ lands in gitignored zig-pkg/. Fixed in tests/e2e/pty.zig answerQueries. Checked with zig build e2e: pty_preview_test passes in a pristine worktree. pty_resize_test still fails on a pristine tree by design and now fails loudly instead of hanging.

## Status

Resolved on 2026-08-23. Same defect as 2026-08-22-pty-e2e-capability-queries-unanswered.md: the split was patched-versus-pristine, not main-checkout-versus-worktree, because patches/ lands in gitignored zig-pkg/. Fixed in tests/e2e/pty.zig answerQueries. Checked with zig build e2e: pty_preview_test passes in a pristine worktree. pty_resize_test still fails on a pristine tree by design and now fails loudly instead of hanging.

## Trigger and scope

Found while landing the non-streaming steer fix
(docs/reports/bugs/2026-08-22-nonstreaming-runs-unsteerable.md) in a worktree:
`zig build e2e` reported two failures, and the first question was whether the
steer change caused them. It did not.

Scope is `zig build e2e` only. It is not part of `clanker gate`, which is why a
green gate does not surface this. The repository rules require every agent
session to work in a worktree, so as things stand an agent cannot get a clean
e2e run and cannot separate its own regression from this one.

## Evidence

Checked on 2026-08-22 at 01c12c13.

Main checkout, clean — passes, and the tail lists both pty journeys as `pass:`:

```bash
cd /home/yannick/code/maci0/clanker
zig build e2e
```

A worktree of the same commit, no modifications at all — fails:

```bash
clanker worktree add .local/worktrees/probe
cd .local/worktrees/probe
zig build e2e
```

`Build Summary: 209/211 steps succeeded (1 failed); 34/36 tests passed (2 failed)`

The two failures are always the same pair, `pty_resize_test` (repl survives a
SIGWINCH flood) and `pty_preview_test` (a `/` prefix previews commands).
Reproduced three times in the worktree and twice in the main checkout, so it is
not flake.

Both fail at the same call:

```
tests/e2e/pty_resize_test.zig:68
try std.testing.expect(try pty_mod.answerQueries(pty.master, &seen, gpa));
```

`answerQueries` is the terminal-capability handshake, where the harness answers
the queries the repl emits at start (kitty graphics, sixel). Returning false
means the expected queries never arrived on the master side.

## Hypotheses and tests

Ruled out, by test:

- **Caused by the steer change under test.** No. Reverting only `src/cli.zig`
  to `origin/main` still fails, and a fully pristine worktree (`git stash -u`,
  clean `git status`) still fails.
- **Caused by the new e2e test registered alongside it.** No. Commenting out
  its `@import` in `tests/e2e/main.zig` leaves both pty failures unchanged.
- **The worktree has no built binary, or the wrong one.** No. The worktree has
  its own `zig-out/bin/clanker` and every other e2e journey that spawns that
  same binary — the `spawnServe` ones included — passes there. Only the pty
  capability handshake behaves differently.

Untested, and recorded as hypotheses rather than findings:

- A start-up timing difference. A worktree build is colder, and
  `answerQueries` presumably has a deadline.
- Something the repl reads at start that resolves differently under a worktree.

## Finding

Superseded 2026-08-23. The failure is not tied to the worktree as such: it is
tied to the worktree being *unpatched*, because `patches/` lands in gitignored
`zig-pkg/`. Root cause found; see "Root cause and resolution" below.

## Resolution or handoff

Open, handed off. The next step is to instrument `answerQueries` to print what
it did receive before its deadline, and to time repl start-up in both trees —
that separates the timing hypothesis from the "reads something different"
hypothesis in one run.

Until then, the working rule for anyone landing a change from a worktree: a
`pty_resize_test` / `pty_preview_test` pair failing there is this issue and not
your change. Confirm by running `zig build e2e` in the main checkout, which is
where the suite is currently trustworthy. Do not silence or skip the tests --
they pass where it matters and the gap is the harness, not the assertions.

## References

- Related bug: none yet

## Root cause and resolution (2026-08-23)

Found, and it is the same defect as
`2026-08-22-pty-e2e-capability-queries-unanswered.md`. That record has the full
evidence, including the instrumented byte stream this record's handoff asked
for; the short version, and specifically what makes it look like a worktree
problem:

`answerQueries` waited for the XTSMGRAPHICS sixel geometry query
(`\x1b[?2;1;0S`) and gated its DA1 answer behind having answered it. Upstream
vaxis 0.6.0 -- the commit `build.zig.zon` pins -- declares that query and never
sends it. Only `patches/vaxis-sixel-graphics.patch` sends it, and `patches/` is
applied into **gitignored** `zig-pkg/`.

That is the whole main-checkout-versus-worktree split this record established
but could not explain. It is not the worktree. It is that the main checkout had
`scripts/apply-patches.sh` run at some point and a fresh worktree has not, and
`zig-pkg/` being gitignored is what makes "fresh worktree" and "unpatched" the
same thing. The timing hypothesis ("a worktree build is colder") and the
"reads something different under a worktree" hypothesis are both wrong; nothing
was timing out, and nothing was read differently. The queries genuinely were
not there.

This record's own evidence was sound and its ruling-out was right -- not the
change under test, not the new test, not the binary. The one hypothesis it did
not list is the one that held: not the tree, the *dependency in* the tree.

Resolution: `answerQueries` now answers the geometry query when it arrives,
skips it when it does not, requires only DA1, and budgets by wall clock instead
of iteration count. `pty_preview_test` passes in a pristine worktree, where it
previously failed at this assertion.

Two corrections to this record's working rule, which said "confirm by running
`zig build e2e` in the main checkout, which is where the suite is currently
trustworthy":

- The main checkout was trustworthy only because it happened to be patched.
  `scripts/apply-patches.sh` is the thing to run, not a different checkout, and
  it is idempotent.
- `pty_resize_test` still fails in a pristine tree after this fix, and
  correctly: it is the regression test for the SIGWINCH crash that
  `patches/vaxis-winch-self-pipe.patch` fixes, so an unpatched tree reproduces
  that crash. It used to *hang* there rather than fail, which is part of why
  this went undiagnosed for so long -- it now fails with
  `error.ReplStoppedReadingTty` naming `scripts/apply-patches.sh`. See
  `docs/reports/bugs/2026-08-23-e2e-pty-harness-is-linux-only.md` for that half
  and for the three other unbounded waits in the same harness.

The instruction "do not silence or skip the tests" was the right call and was
followed: no assertion was weakened. What changed is that the harness no longer
requires an optional local patch to complete a handshake that has nothing to do
with sixel.