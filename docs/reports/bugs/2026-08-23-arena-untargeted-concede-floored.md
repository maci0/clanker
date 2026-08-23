# Bug — Arena floored untargeted concede and final_stand moves

## TL;DR

- **What failed:** Battle Royale paid the weak-confidence floor for every move that named no target, including concede/final_stand which the prompt does not require a target for; a protocol-following concession was recorded weak at 0.15. Fixed by gating the floor on needsTarget. PR 351.
- **Impact:** In Battle Royale mode a combatant that followed the move protocol exactly — an untargeted `concede` or `final_stand`, which the prompt does not require a target for — was recorded `weak` at confidence 0.15 and misrepresented in the match record and verdict.
- **Resolution:** Resolved on 2026-08-23. Fixed in PR 351 (merged 2026-08-23); verified by the needsTarget unit test and a live 3-way deepseek match record.

## Status

Resolved on 2026-08-23. Fixed in PR 351 (merged 2026-08-23); verified by the needsTarget unit test and a live 3-way deepseek match record.

## Symptom and impact

tools/zig/arena.zig paid the weak-confidence floor for every move whose target failed to resolve, but the combatant prompt marks `target` REQUIRED only for attack, block and counter, and `score()` ignores the target of `concede`/`final_stand` entirely. A legitimate untargeted concession or closing argument was floored and flagged weak.

## Reproduction

Live 3-way deepseek match (self-judged, 2 rounds) with one combatant instructed to concede with no target field: pre-fix code floored exactly this shape (`if (retargeted)` fired for any unresolved target).

## Root cause

The retarget fallback (`defaultTarget`) and the omission penalty were fused: any unresolved target implied both a default aim and the floor, regardless of whether the move needed aiming at all.

## Resolution

PR 351 (merged 2026-08-23). `needsTarget` (tools/zig/arena_match.zig) gates the floor to attack/block/counter, judged on the parsed move so a `final_stand` outside the last round is floored once by `legalize`, not twice. The `retargeted` record flag keeps meaning "offensive move that was default-aimed"; the documented default-aim decision for untargeted offensive moves is unchanged.

## Verification

Unit test for the `needsTarget` table; live match record post-fix shows `move: concede, target absent, confidence 0.9, weak: false`. Gate green: 339/339 steps, 1948/1959 passed (11 skipped). PRD 0008's known-issue bullet updated.

## Follow-up

## References

- Investigation: none yet
