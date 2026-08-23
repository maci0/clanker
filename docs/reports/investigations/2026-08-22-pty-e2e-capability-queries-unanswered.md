# Investigation — Two pty e2e journeys fail on an untouched base: the REPL's vaxis capability queries never arrive

## TL;DR

- **Question:** zig build e2e fails 2 of 34 on clean origin/main (3d409a98): pty_resize_test and pty_preview_test both fail at pty.answerQueries, the spawned REPL's sixel-geometry and DA1 queries not arriving inside the answer window. Reproduced with the working tree stashed, so it is a property of the checkout/environment, not of any change under test. Same symptom was recorded as an aside in the 2026-08-17 /rfc investigation and never got its own record.
- **Finding:** RESOLVED 2026-08-23, and not environmental: answerQueries waited for a sixel geometry query that only a locally applied patch makes the repl send, and gated the DA1 answer behind it. See "Root cause and resolution" below.
- **Resolution:** Resolved on 2026-08-23. answerQueries no longer requires the XTSMGRAPHICS geometry query, which only patches/vaxis-sixel-graphics.patch makes the repl send, and no longer gates the DA1 answer behind it; iteration budget replaced by a 5s wall-clock deadline. Checked with zig build e2e, not the gate (which compiles no tests/e2e/): pty_preview_test passes on a pristine tree where it previously failed at this assertion, and 37/38 with both pty journeys pass after scripts/apply-patches.sh.

## Status

Resolved on 2026-08-23. answerQueries no longer requires the XTSMGRAPHICS geometry query, which only patches/vaxis-sixel-graphics.patch makes the repl send, and no longer gates the DA1 answer behind it; iteration budget replaced by a 5s wall-clock deadline. Checked with zig build e2e, not the gate (which compiles no tests/e2e/): pty_preview_test passes on a pristine tree where it previously failed at this assertion, and 37/38 with both pty journeys pass after scripts/apply-patches.sh.

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

## Root cause and resolution (2026-08-23)

Found. Not environmental, and not about headless sessions: the harness was
waiting for a byte sequence the repl never sends.

`answerQueries` waited for the XTSMGRAPHICS sixel geometry query
(`\x1b[?2;1;0S`) and gated its DA1 arm behind having answered it. Upstream
vaxis 0.6.0 -- `82cec0db`, the exact commit `build.zig.zon` pins -- *declares*
`ctlseqs.sixel_geometry_query` and never sends it. `Vaxis.queryTerminal` emits
the DECRQM set, the explicit-width and scaled-text probes, `xtversion`,
`csi_u_query`, `kitty_graphics_query` and `primary_device_attrs`, and stops.
Only `patches/vaxis-sixel-graphics.patch` adds the geometry query, and
`patches/` is applied into gitignored `zig-pkg/`, so any tree that has not run
`scripts/apply-patches.sh` runs pristine vaxis.

So DA1 arrived, sat in the buffer, and was never answered, because the arm that
would have answered it required a query that was never coming.

The instrumentation the handoff asked for, run on aarch64-macos. Every escape
the repl emitted, in order:

```
\x1b[?1049h  \x1b[?1016$p  \x1b[?2027$p  \x1b[?2031$p  \x1b[?2048h
\x1b[H  \x1b]66;w=1; \x1b\  \x1b[6n  \x1b[H  \x1b]66;s=2; \x1b\  \x1b[6n
\x1b[> q  \x1b[6n  \x1b[>0q  \x1b[?u  \x1b_Gi=1,a=q\x1b\  \x1b[c   ...
```

No `\x1b[?2;1;0S`. Probe counters: `iters=60 pumps=60 closed=false geom=false
da1=false elapsed_ms=2914 bytes=1613`.

This also settles the "run it from an interactive terminal" handoff as
unnecessary: the split was never headless-versus-attached. It was
patched-versus-pristine, and `patches/README.md` had said so all along
("the e2e pty journeys ... fail on an unpatched dependency until
`scripts/apply-patches.sh` has run") without anyone connecting that paragraph
to this record.

Fix, in `tests/e2e/pty.zig`:

- The geometry query is answered when it arrives and skipped when it does not.
  Only DA1 is required, which is the query that actually ends the query phase.
  Ordering still holds where it matters: the patched query phase sends geometry
  *before* DA1, so a stream carrying both is seen and answered in that order and
  the sixel renderer still engages.
- The 60-iteration budget became a 5s wall-clock deadline. An iteration count is
  not a timeout: `pump` returns the moment bytes are available, so a repl that
  writes a burst before its queries can burn any fixed number of iterations in
  milliseconds. `pty_resize_test` had already learned that for its own settle
  loops; the handshake had not.

What this does **not** buy, stated plainly because a green e2e should not be
over-read: on a pristine tree `sixel_supported` is false and every SIXEL path in
`mascot.zig` is compiled out, so these journeys now pass while exercising
strictly *less* than the same journeys in a patched checkout. And
`pty_resize_test` still fails on a pristine tree for an unrelated and correct
reason -- it is the regression test for the SIGWINCH crash that
`patches/vaxis-winch-self-pipe.patch` fixes, so an unpatched tree reproduces
that crash. It now fails with `error.ReplStoppedReadingTty` naming
`scripts/apply-patches.sh`, where it previously hung forever.

Verified with `zig build e2e` explicitly (the gate compiles none of
`tests/e2e/`): `pty_preview_test` passes on a pristine tree where it previously
failed at this assertion, and the full suite reports `37/38 tests passed` with
both pty journeys `pass:` after `scripts/apply-patches.sh`. The one remaining
failure is `live_sse_test`, unrelated, filed as
`docs/reports/bugs/2026-08-23-events-slot-not-released-on-hangup.md`.