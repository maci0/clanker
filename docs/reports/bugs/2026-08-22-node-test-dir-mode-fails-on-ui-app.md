# Bug — node --test on ui/app fails in directory mode while every file passes

## TL;DR

- **What failed:** `node --test ui/app/` reports one opaque top-level failure while running each of the `ui/app` `*.test.mjs` files individually passes. Node resolves the positional as a *module* path, so the directory itself is loaded as the test file and dies `MODULE_NOT_FOUND`; node has no working directory mode.
- **Impact:** The directory invocation cannot be trusted as a gate; a real failure could hide inside the aggregate, and a green per-file sweep looks contradictory next to it.
- **Resolution:** Resolved on 2026-08-22. node accepts test files and glob patterns, not directories: the positional is loaded as the entry module and fails MODULE_NOT_FOUND on the directory itself (traced on node v24.18.1). Sweep form 'node --test ui/**/*.test.mjs' documented in README/CONTRIBUTING/docs/README/AGENTS, and clanker gate gained js-suite-coverage so build.zig's hand-written suite list cannot silently miss a file.

## Status

Resolved on 2026-08-22. node accepts test files and glob patterns, not directories: the positional is loaded as the entry module and fails MODULE_NOT_FOUND on the directory itself (traced on node v24.18.1). Sweep form 'node --test ui/**/*.test.mjs' documented in README/CONTRIBUTING/docs/README/AGENTS, and clanker gate gained js-suite-coverage so build.zig's hand-written suite list cannot silently miss a file.

## Symptom and impact

On node v24.18.1, `node --test ui/app/` ends with:

```
✖ ui/app (43ms)
  'test failed'
ℹ tests 1
ℹ pass 0
ℹ fail 1
```

The failure names the directory itself (`test at ui/app:1:1`), not any test file, and every individual subtest line above it is green. Running the same files one at a time (`for f in ui/app/**/*.test.mjs; node --test "$f"`) passes all of them — 19 files at the time of writing.

## Reproduction

From the repo root on main (reproduced identically at 60505fe0, 7912ba89 and
3d409a98, 2026-08-22):

```
node --test ui/app/
```

The per-file loop passes. So does the quoted glob, which is the form to use:

```
node --test 'ui/**/*.test.mjs'
```

And so does the no-positional form, which discovers recursively from the
current directory:

```
cd ui && node --test
```

## Root cause

Traced 2026-08-22 on node v24.18.1. A positional argument to `node --test` is a
test *file* path (or a glob pattern node expands itself), never a directory to
search. `node --test ui/app/` therefore hands node the directory as the entry
module; the runner reports it as a single test named after the path, and the
run's real output is the loader's stack:

```
Error: Cannot find module '/…/clanker/ui/app'
    at Module._resolveFilename (node:internal/modules/cjs/loader:1517:15)
    at Module.executeUserEntryPoint [as runMain] (node:internal/modules/run_main:154:5)
  code: 'MODULE_NOT_FOUND'
```

Nothing under `ui/` is involved: a scratch directory holding one passing
`*.test.mjs` fails identically, with and without the trailing slash. The two
forms that do sweep a tree are a quoted glob and the no-positional form, which
discovers recursively from the current directory.

The report's original version number (node 26.6.0) could not be reproduced or
checked — v24.18.1 is what is installed on this machine, and it is what every
observation here was taken on.

## Resolution

Resolved. There is nothing to fix in node's behaviour and nothing in the
checkout was at fault, so the fix is in the two places that made the directory
form look necessary:

1. The sweep form is now written down where the per-file loop already was
   (`README.md`, `CONTRIBUTING.md`, `docs/README.md`, `AGENTS.md`):
   `node --test 'ui/**/*.test.mjs'`, quoted so node expands it, with a note
   that a directory positional is resolved as a module and fails.
2. `clanker gate` gained a `js-suite-coverage` check
   (`jsSuiteCoverageGate` in `src/gate/checks.zig`). `build.zig` names each
   `.test.mjs` by hand, so an unregistered suite is never run and the green
   suite output cannot show it — the gap the directory invocation was reached
   for. The gate walks `ui/` and fails on any suite `build.zig` does not
   name.

## Verification

`node --test 'ui/**/*.test.mjs'` from the repo root: 223 tests, 27 files,
`fail 0` (2026-08-22, node v24.18.1). The gate was checked in both directions
with a scratch `ui/app/core/zzz-unregistered.test.mjs`:
`zig build test -Dtest-filter="jsSuiteCoverageGate"` fails on the
live-checkout assertion while that file exists, and passes once it is removed.
That the failing verdict names the offending paths is pinned separately by
`scanUnrunJsSuites names a suite zig build test would never run`, which runs
the scan against a `build.zig` text registering nothing.

## Follow-up

The bisect this record proposed is unnecessary — no file under `ui/` is
involved, the directory path itself is what node fails to load.

## References

- `jsSuiteCoverageGate` / `scanUnrunJsSuites` in `src/gate/checks.zig`, wired
  into `verifyGates` in `src/cli.zig`.
- The hand-written suite list: the `node --test` `addSystemCommand` steps in
  `build.zig`.
