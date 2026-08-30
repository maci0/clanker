# Bug — gate lint/provider-kind steps cannot read a .zig file past 1 MiB

## TL;DR

- **What failed:** clanker gate fails at the lint step with StreamTooLong once any repo .zig file exceeds 1 MiB (src/cli.zig crossed it): lintGate, providerKindLeakGate and scanForUnrootedTests read every file with a fixed readFileAlloc limit that errors when the size reaches the cap, so an over-cap file is reported as an unreadable changed file and the gate can never pass; the webui-budget test failure on main masked it until that test was fixed.
- **Impact:** `clanker gate` can never pass on a tree where any .zig file is at or above 1 MiB, so no change can be validated or committed through the normal flow. On main this was masked one step earlier by the webui-budget test failure (see 2026-08-27 record), which is why the lint step had never been observed failing.
- **Resolution:** Resolved on 2026-08-30. Fixed in src/gate/checks.zig: the three scanning gates read through readWholeFile, which stats the file and reads with .limited(max(size, 1 MiB)+1) instead of a fixed cap, plus two >1 MiB regression tests. Verified: zig build test green and clanker gate green (all 14 steps) with src/cli.zig at 1,057,001 bytes.

## Status

Resolved on 2026-08-30. Fixed in src/gate/checks.zig: the three scanning gates read through readWholeFile, which stats the file and reads with .limited(max(size, 1 MiB)+1) instead of a fixed cap, plus two >1 MiB regression tests. Verified: zig build test green and clanker gate green (all 14 steps) with src/cli.zig at 1,057,001 bytes.

## Blocked on

## Symptom and impact

`clanker gate` fails at the lint step once `src/cli.zig` crossed 1 MiB (1,057,001 bytes):

```
lint: could not read ./src/cli.zig: StreamTooLong
lint: a changed file could not be scanned
```

The gate aborts on the first failed step, so nothing after lint (provider-kind,
test-root-coverage, js-suite-coverage, webui-budget, …) ever runs, and no
change in the repo can be validated. The same latent read cap also sat in the
provider-kind gate (1 MiB) and the unrooted-test scan (4 MiB), so a large
file breaks every one of those steps the same way.

## Reproduction

```
src/cli.zig is 1,057,001 bytes (> 1 MiB) on main
$ clanker gate
# fails at: lint — "could not read ./src/cli.zig: StreamTooLong"
```

The regression tests in `src/gate/checks.zig` (`lintGate decides files past
the 1 MiB scan cap by their content`, `providerKindLeakGate reads files past
the 1 MiB scan cap`) build a file just over the cap and assert the verdict
comes from the scan itself: both fail on the old fixed-cap read and pass with
the stat-sized read.

## Root cause

`lintGate`, `providerKindLeakGate` and `scanForUnrootedTests` read every repo
`.zig` file with `dir.readFileAlloc(io, path, gpa, .limited(1 << 20))` (the
third with `4 << 20`). In Zig 0.16 an `Io.Limit.limited(n)` answers
`error.StreamTooLong` when the file size *reaches or exceeds* n, so a file of
exactly 1 MiB already failed and any larger file always did. The cap was
meant as a sanity bound on scan input, but the gate scans the whole repo,
where `src/cli.zig` now legitimately exceeds it — the cap turned "the file is
big" into "the file is unreadable".

## Resolution

`src/gate/checks.zig` gained a `readWholeFile` helper: stat the file, then
read with `.limited(@max(st.size, 1 MiB) + 1)` — the limit sits one byte past
the size because a limit reached or exceeded is the error case. If the stat
fails, it falls back to the old fixed-cap read (a file that cannot be stat'ed
is not a "the repo grew" case). All three scanning gates call it instead of
their fixed-cap reads, so an over-cap file is decided by its content exactly
like a smaller one.

## Verification

- `zig build test`: both new >1 MiB regression tests pass (lint gate flags the
  dirty over-cap file by content and passes the clean one; provider-kind reads
  a clean over-cap file ok).
- `clanker gate`: green on a tree where `src/cli.zig` is 1,057,001 bytes —
  the exact configuration that failed before the fix.

## Follow-up

Other callers of `readFileAlloc` with a fixed `.limited(...)` cap are
intentional "file too large" signals for their inputs; the three gate scans
were the only whole-repo scanners. If the repo ever adds another
whole-tree scan, size the read from stat the same way.

## References

- Masking bug, fixed the same session: docs/reports/bugs/2026-08-27-webui-weight-budget-exceeded-by-100-bytes.md
