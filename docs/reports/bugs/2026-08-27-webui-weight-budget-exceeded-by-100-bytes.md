# Bug — webui-budget gate fails: eager JS is 144.1K gz against a 144K budget

## TL;DR

- **What failed:** ui/app/weight-budget.test.mjs fails by 0.1K gz, so zig build test and clanker gate are red on a tree whose eager JS is byte-identical to the last several pushes. Not caused by any recent merge.
- **Impact:** `zig build test` and `clanker gate` exit non-zero, so every gated change is blocked behind a failure it did not cause.
- **Resolution:** Resolved on 2026-08-30. budget raised 144 -> 145K in ui/app/weight-budget.test.mjs: the 44abfedd bytes are a deliberate a11y fix, not accretion; verified by node ui/app/weight-budget.test.mjs and clanker gate, both green

## Status

Resolved on 2026-08-30. budget raised 144 -> 145K in ui/app/weight-budget.test.mjs: the 44abfedd bytes are a deliberate a11y fix, not accretion; verified by node ui/app/weight-budget.test.mjs and clanker gate, both green

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

Established. `44abfedd` ("fix: real button for run rows and named values on
music sliders") is the crossing commit: measured eager JS was 143.96K gz before
it and 144.06K after, over the 144K budget by ~61 gz bytes. The bytes are the
fleet run rows' `href="#"` anchor replaced with a real `<button type="button">`
(plus its explanatory comment) in `ui/app/app.js` — a deliberate accessibility
fix, not accretion. The gauntlet merges of 2026-08-26 changed no eager bytes;
they merely carried the already-red total.

## Resolution

Raise the budget 144 -> 145, on purpose, in `ui/app/weight-budget.test.mjs`,
with the reason recorded in the test's own comment. The test's header is the
procedure for exactly this moment: "decide whether the bytes are worth it (and
raise the budget on purpose) rather than deleting the check". The 44abfedd
bytes are worth it (button semantics for screen readers), and trimming them —
shaving the comment or the name to get back under 144K — would make the budget
a constraint on reviewed accessibility work. 145K keeps 0.9K of headroom, so
the budget still sits at the measured floor and catches the next accretion.

## Verification

- `node ui/app/weight-budget.test.mjs` — 6 pass, 0 fail (was 5 pass, 1 fail).
- `clanker gate` — test step green; all gates pass.

## Follow-up

## References

- Investigation: none yet
