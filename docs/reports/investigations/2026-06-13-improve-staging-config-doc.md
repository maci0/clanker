# Investigation — improve-self iterations exhaust attempts on config.toml documentation test

## TL;DR

- **Question:** improve-self wrapper stops after iterations 1-2 each exhaust all attempts. Baseline gate shows 2.00/3 passing (tests failing). Staging gate fails the test 'config.toml documents every key the loader accepts', output truncated by tail-only gate output so the undocumented key is hidden. Investigating root cause and whether gate.zig tail-truncation hides diagnostics.
- **Finding:** Both halves confirmed: the test's cwd dependency, and a tail-only gate window that hid the diagnosis.
- **Resolution:** Resolved on 2026-08-16.

## Status

Resolved on 2026-08-16. gate.zig failureWindow anchors on the last diagnostic line and the config doc test reads @embedFile("config_toml"); both verified in the current tree.

## Trigger and scope

An improve-self wrapper stopped after iterations 1 and 2 each exhausted their
attempts. The baseline gate showed 2.00/3 and the staging gate failed
`config.toml documents every key the loader accepts`, with the gate output
truncated so the undocumented key never appeared. Two questions: why the test
failed, and whether the gate's tail-only output hid the diagnosis.

## Evidence

- The doc-coverage test read `config.toml` from the runtime cwd, which an
  improve staging worktree does not necessarily have, so the failure was about
  the staging tree rather than about any missing key.
- `zig` prints its real `file.zig:line:col: error:` lines *before* the closing
  summary and the `error: the following build command failed` banner with its
  argv dump. A fixed last-N-bytes tail therefore lands on the banner and shows
  nothing diagnostic.

## Hypotheses and tests

Both hypotheses held, and both are visible in the current tree rather than
needing the batch re-run.

## Finding

Confirmed, and both halves are fixed.

- `tools/zig/gate.zig` `failureWindow` anchors the window on the *last real
  diagnostic error line*, walking backwards and skipping the build-command
  banner, then trims a trailing argv dump that lands inside the window. The
  fixed tail survives only as a fallback when no diagnostic line exists. Its
  doc comment records the cost of the old behaviour: "the improvement engine
  once burned two full iterations failing blind".
- `src/config.zig` reads the file through `@embedFile("config_toml")`, so the
  doc-coverage test has no cwd dependency and a staging worktree cannot fail
  it. Same fix as the follow-up in
  [improve-self gate tool build failure](2026-04-15-improve-self-gate-build.md).

## Resolution or handoff

Resolved. No handoff.

## References

- Related bug: none yet

## Enhancement 2026-08-16

`failureWindow` now also handles `zig build test` transcripts: a failing test
prints a `✘`-prefixed line in the middle of a long log (its `error:`-free, since
passing config tests deliberately load a bad file and log it), so the window
prefers the first `✘` marker when one exists, otherwise the first real
diagnostic line. It also decodes the exec-wrapper JSON `stdout` before windowing
(the wrapper escapes the transcript) and spills the full decoded transcript to
`zig-out/gate-failure.txt` when a build or test fails, so the complete diagnostic
survives display truncation. Window capped at 3000 bytes.
