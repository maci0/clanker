# Bug — lint gate fails StreamTooLong once src/cli.zig crossed 1 MiB

## TL;DR

- **What failed:** `lintGate` (and `providerKindLeakGate`) read each scanned file with a 1 MiB `readFileAlloc` ceiling. `clanker gate` hands them every `.zig` file in the tree, and `src/cli.zig` reached 1,057,001 bytes, so the read failed with `StreamTooLong` and the unreadable-file rule correctly turned that into a red gate — on an untouched checkout.
- **Impact:** `clanker gate` red for every change on a tree whose `src/cli.zig` is over 1 MiB, right after the tests step went green.
- **Resolution:** Fixed: both scans read with a 4 MiB ceiling. The fail-closed rule for unreadable files stays — the ceiling just has to sit above the files the scan legitimately walks.

## Status

Resolved.

## Reproduction

`clanker gate` on c43c291f: build, tests, tools, fmt PASS, then
`lint: could not read ./src/cli.zig: StreamTooLong` and `lint: FAIL`.

## Root cause

A fixed `.limited(1 << 20)` in two whole-tree scans, outgrown by the file it
scans most.

## Verification

Full `clanker gate` (built from this branch, since the ceiling lives in the
gate binary itself) passes on this tree.

## Follow-up

## References

- Investigation: none yet
