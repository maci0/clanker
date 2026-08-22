# Investigation — The two pty e2e tests fail in any git worktree and pass in the main checkout

## TL;DR

- **Question:** zig build e2e fails pty_resize_test and pty_preview_test in a PRISTINE worktree at the same commit that passes in the main checkout. Both die at pty.answerQueries, the terminal-capability handshake, so the repl's queries never reach the test. Every agent session works in a worktree per the repository rules, so e2e is effectively unrunnable there. Root cause not yet found.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

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

Established: the failure is environmental, tied to running in a git worktree,
and is not caused by any source change. Root cause not found.

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
