# Bug — Copy fallback selects no input value

## TL;DR

- **What failed:** Copy buttons fall back to an empty selection when the Clipboard API is unavailable. Commit 2fd50f87 selects and focuses the labelled input; clipboard regressions, lint, typecheck and end-to-end tests pass.
- **Impact:** Users relying on manual copy receive a selected, accessible value after the fix.
- **Resolution:** Resolved on 2026-10-01. Fixed in 2fd50f87; pre-fix clipboard regressions failed, fixed tests, lint, typecheck and end-to-end tests passed.

## Status

Resolved on 2026-10-01. Fixed in 2fd50f87; pre-fix clipboard regressions failed, fixed tests, lint, typecheck and end-to-end tests passed.

## Blocked on

## Symptom and impact
Copy buttons on origins without the Clipboard API offered an empty selection for manual copying.

## Reproduction
Run bun test ui/app/core/vendor.test.mjs against c8fda468: the focused-input and accessible-label tests fail. At 2fd50f87 all four pass.

## Root cause
ui/app/core/vendor.js used Range.selectNodeContents on an input, which has no text child. See the [investigation](../investigations/2026-10-01-copy-input-selection.md).

## Resolution
Commit 2fd50f87 focuses and selects a labelled, readonly input and removes it on blur, so the user has time to copy its value.

## Verification
The pre-fix regressions failed. After the fix, clipboard tests, lint, typecheck and zig build e2e passed; the other scripts/verify.sh gates passed. The lint baseline was preserved.

## Follow-up
None required for this fallback. See the [runbook](../../runbooks/copy-input-selection.md) when investigating a recurrence.

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: [Copy input selection](../investigations/2026-10-01-copy-input-selection.md)
