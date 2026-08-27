# Bug — webui-budget gate fails: eager JS is 144.1K gz against a 144K budget

## TL;DR

- **What failed:** ui/app/weight-budget.test.mjs fails by 0.1K gz, so zig build test and clanker gate are red on a tree whose eager JS is byte-identical to the last several pushes. Not caused by any recent merge.
- **Impact:** `zig build test` and `clanker gate` exit non-zero, so every gated change is blocked behind a failure it did not cause.
- **Resolution:** Open.

## Status

Open.

## Blocked on

## Symptom and impact

`ui/app/weight-budget.test.mjs` asserts `eagerJsGz <= 144`. It measures 144.1K,
so the `test` step fails and `clanker gate` stops there. All 2156 Zig tests pass
(1 skipped); this is the only failing suite.

## Reproduction

```
bun test ui/app/weight-budget.test.mjs
```

```
AssertionError: eager JS is 144.1K gz; budget is 144K
    at ui/app/weight-budget.test.mjs:104:10
```

## Root cause

Not established. The overshoot is ~0.1K gz across 33 eager requests. It predates
the gauntlet merges of 2026-08-26: `git diff origin/main main -- ui/app/index.html
ui/app/app.js ui/app/core/ ui/app/lib/ ui/app/preact-boot.js ui/vendor/` was empty
across those commits, so the measured bytes were unchanged by them, and the CI run
for e510cb69 on `main` already failed.

## Resolution

Open. Two routes, and the choice is the decision this report is asking for:

- Find the ~100 gz bytes that pushed it over and trim them, keeping the budget at
  the measured floor the test comment argues for.
- Raise the budget, which the test comment argues against: "a budget left far
  above the real number stops catching the accretion it exists to catch".

## Verification

None yet.

## Follow-up

## References

- Investigation: none yet
