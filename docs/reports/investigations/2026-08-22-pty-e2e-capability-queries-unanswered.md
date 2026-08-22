# Investigation — Two pty e2e journeys fail on an untouched base: the REPL's vaxis capability queries never arrive

## TL;DR

- **Question:** zig build e2e fails 2 of 34 on clean origin/main (3d409a98): pty_resize_test and pty_preview_test both fail at pty.answerQueries, the spawned REPL's sixel-geometry and DA1 queries not arriving inside the answer window. Reproduced with the working tree stashed, so it is a property of the checkout/environment, not of any change under test. Same symptom was recorded as an aside in the 2026-08-17 /rfc investigation and never got its own record.
- **Finding:** Provisional and environmental — the same two tests failed the same way on 2026-08-17; `clanker gate` is unaffected.
- **Resolution:** Open. Needs one `zig build e2e` run from an interactive terminal to split "headless session" from "defect in pty.zig or the REPL".

## Status

Investigating.

## Trigger and scope

Verifying an unrelated fix (the `llm_start` serve-stream frame) with `zig build e2e`, which is not part of `clanker gate` and so is run by hand. Scope is the e2e suite only: `clanker gate` (build, test, tools, fmt, lint, provider-kind, test-root-coverage, sandbox-abi, tools-ts-toolchain, release-contract) passes in the same worktree.

## Evidence

Worktree at `origin/main` (3d409a98) plus one change under test, 2026-08-22:

- With the change applied: `zig build e2e` exits 1, 33 of 35 pass. Failures are `pty_resize_test` "repl survives a SIGWINCH flood on a pty" (line 68) and `pty_preview_test` "typing a / prefix previews matching commands with their help" (line 137), both at `try std.testing.expect(try pty_mod.answerQueries(pty.master, &seen, gpa))`.
- With the same worktree stashed (`git stash -u`, tree byte-identical to `origin/main`): `zig build e2e` exits 1, 32 of 34 pass, the same two tests failing at the same two lines. The change under test therefore does not cause them.
- Environment: headless agent session, cachyos, Linux 7.1.5-1, Zig 0.16.0. No interactive terminal attached to the session.

`answerQueries` returning false means the spawned REPL's vaxis capability queries (sixel geometry, then DA1) did not arrive on the pty master inside its answer window. Not traced further than that: what was checked is which assertion fails and that it fails without the change, not why the queries are absent.

## Hypotheses and tests

Untested. The one hypothesis worth recording is that the failure is environmental rather than a defect in the REPL or in `pty.zig`: the same two tests were reported failing the same way on 2026-08-17 in this checkout (see References), and the record there notes it was "not yet reproduced on an interactive terminal". Nobody has yet run `zig build e2e` from an interactive terminal on this machine to confirm or refute that split.

## Finding

Provisional: the two pty journeys are unreliable in headless agent sessions on this checkout, and have been since at least 2026-08-17. A change under test cannot be cleared or blamed by `zig build e2e`'s exit code alone here — the suite must be run stashed as well, and the two failures compared.

## Resolution or handoff

Open. Handoff: run `zig build e2e` from an interactive terminal on this machine and record whether the two tests pass there. If they do, the queries are absent because of the headless session and the tests need either a longer answer window or a skip when no terminal is attached; if they fail there too, the cause is in `tests/e2e/pty.zig` or in the REPL's query emission and belongs in a bug report.

## References

- `docs/reports/investigations/2026-08-17-missing-clanker-tool-rfc-slash-command-in-tui.md` — records the same two failures under "Issue encountered while verifying", reproduced three times on 2026-08-17 including once against a stashed tree.
- `docs/reports/investigations/2026-08-17-pty-text-assertions-race-the-cell-diff.md` — why the pty text assertions force a repaint and match despaced; unrelated to the query timeout, but the origin of `tests/e2e/pty.zig`.
- Related bug: none yet
