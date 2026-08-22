# Bug — node --test on ui/app fails in directory mode while every file passes

## TL;DR

- **What failed:** `node --test ui/app/` reports one opaque top-level failure while running each of the `ui/app` `*.test.mjs` files individually passes.
- **Impact:** The directory invocation cannot be trusted as a gate; a real failure could hide inside the aggregate, and a green per-file sweep looks contradictory next to it.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

On node 26.6.0, `node --test ui/app/` ends with:

```
✖ ui/app (43ms)
  'test failed'
ℹ tests 1
ℹ pass 0
ℹ fail 1
```

The failure names the directory itself (`test at ui/app:1:1`), not any test file, and every individual subtest line above it is green. Running the same files one at a time (`for f in ui/app/**/*.test.mjs; node --test "$f"`) passes all of them — 19 files at the time of writing.

## Reproduction

From the repo root on main (reproduced identically at 60505fe0 and 7912ba89, 2026-08-22):

```
node --test ui/app/
```

Compare with the per-file loop, which passes.

## Root cause

Not traced. Suspicion: node's directory discovery executes a non-test module (or the directory entry itself) whose top-level evaluation fails outside the harness a `.test.mjs` file expects.

## Resolution

Open. Until traced, gate webui JS changes with the per-file loop, not the directory invocation.

## Verification

Pending a fix: `node --test ui/app/` should report the same pass count as the per-file sweep and `fail 0`.

## Follow-up

- Bisect by moving files out of the directory until the aggregate failure disappears; the last file standing is the one directory discovery chokes on.

## References

- Investigation: none yet
