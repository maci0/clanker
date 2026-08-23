# Investigation — The SIGWINCH flood journey fails in any worktree where apply-patches.sh has not been run

## TL;DR

- **Question:** zig build e2e is 37/38 in a fresh worktree, failing pty_resize_test with ReplCrashedOnResize after only a handful of resizes. zig-pkg is gitignored and therefore per-worktree, so a fresh worktree has pristine vaxis and the SIGWINCH self-pipe patch is absent — the exact crash the journey exists to catch. Running scripts/apply-patches.sh (4 applied, 0 already up to date) makes the whole suite green. Not a regression on origin/main.
- **Finding:** The patches were never applied in the worktree: `scripts/apply-patches.sh` reported "4 applied, 0 already up to date", and `zig build e2e` went green immediately after.
- **Resolution:** Resolved on 2026-08-23. No code defect: zig-pkg is gitignored so a fresh worktree runs pristine vaxis; scripts/apply-patches.sh applied 4 of 4 and e2e went green on the same commit. The failure message now names the check.

## Status

Resolved on 2026-08-23. No code defect: zig-pkg is gitignored so a fresh worktree runs pristine vaxis; scripts/apply-patches.sh applied 4 of 4 and e2e went green on the same commit. The failure message now names the check.

## Trigger and scope

Two parallel agents independently hit `zig build e2e` at 37/38 on
`origin/main` (`2d397af5`) and both read it as a pre-existing code defect in
the REPL. It is neither pre-existing in the code nor a defect: it is the
worktree's dependency cache.

## Evidence

- A detached worktree at `origin/main` (`2d397af5`), untouched: 37/38, the
  journey printing `repl died after 8 resizes (killed by a signal)`. Eight, not
  the ~1500 the test's own header gives for the unfixed build under load —
  which is the tell that the fix is simply absent rather than marginal.
- `grep -rn "self_pipe" zig-pkg/vaxis-0.6.0-*/src/*.zig` in that worktree:
  nothing.
- `scripts/apply-patches.sh`: `4 applied, 0 already up to date` — so none of
  the four were active, including `vaxis-winch-self-pipe.patch`.
- `zig build e2e` immediately after, same worktree, same commit: green,
  including `pass: operator journey: repl survives a SIGWINCH flood on a pty`.

## Hypotheses and tests

1. *A regression on `origin/main`.* Ruled out: the same commit passes once the
   patches are applied, with no source change.
2. *A worktree artifact like the one in
   `2026-08-22-pty-e2e-fails-in-a-worktree.md`.* Adjacent but not the same:
   that one was the sixel geometry query going unanswered, and it was fixed in
   `answerQueries`. This is the winch patch, and it is not a code question at
   all.
3. *The dependency cache is per-worktree.* Confirmed: `.gitignore:6` lists
   `zig-pkg/`, so every new worktree gets pristine tarballs from
   `zig build`, and `scripts/apply-patches.sh` is what re-applies the local
   fixes. Its own header says so: "without the vaxis SIGWINCH self-pipe patch,
   resizing the terminal in `clanker repl` aborts the process".

## Finding

`zig-pkg/` is gitignored, so a fresh worktree runs pristine vaxis, which still
services SIGWINCH inside the signal handler. That is the precise crash
`pty_resize_test` was written to catch, so the journey does exactly its job —
it just gets read as a regression, because nothing in the failure output for
the died-by-signal branch mentions the patches. The neighbouring
`ReplStoppedReadingTty` branch does name `scripts/apply-patches.sh`; the
branch that actually fires did not.

## Resolution or handoff

Closed on 2026-08-23, no code defect. The `ReplCrashedOnResize` branch now
leads with the check: `zig-pkg/` is per-worktree, run
`scripts/apply-patches.sh`, and read a death inside the first few dozen
resizes as the missing patch rather than a regression.

Worth knowing for anyone gating in a worktree: `clanker gate` does not run
e2e, so it passes on unpatched dependencies without complaint. The keypad-Enter
and sixel behaviours are also inert until the script has run.

## References

- Original crash: `docs/reports/investigations/2026-08-16-tui-resize-crash.md`
  and `docs/reports/bugs/2026-08-17-tui-resize-crash-sigwinch-in-signal-handler.md`
- Adjacent worktree artifact: `docs/reports/investigations/2026-08-22-pty-e2e-fails-in-a-worktree.md`
- `patches/README.md`, `scripts/apply-patches.sh`

- Related bug: none yet
