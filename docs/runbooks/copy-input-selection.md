# Runbook — Copy fallback selects no input value

## TL;DR

- **Use when:** Use a labelled input, focus it, select its value, and remove it when focus leaves. Verify the clipboard tests and UI gates.
- **Recover by:** Update to 2fd50f87 or later and preserve the focused input selection.
- **Verify with:** bun test ui/app/core/vendor.test.mjs, lint, typecheck and zig build e2e.

## Scope and preconditions
Use when a web copy button cannot use navigator.clipboard and offers no selected value. The shared fallback is ui/app/core/vendor.js.

## Diagnose
Run bun test ui/app/core/vendor.test.mjs. Trace copyText's fallback and verify that the input itself receives focus() and select().

## Recover
Update to 2fd50f87 or later. Keep the accessible input label, readonly value and blur cleanup when changing this path.

## Verify
The four clipboard tests pass; bun run lint, bun run typecheck and zig build e2e also pass. A pre-fix checkout fails the focused-input regressions.

## Escalate or follow up
If these checks pass but copying still fails, record the browser and origin in a new investigation before changing the shared fallback.

## Diagnose

## Recover

## Verify

## Escalate or follow up

## References

- Report: [Copy input selection](../reports/bugs/2026-10-01-copy-input-selection.md)
- Last verified: 2026-10-01, 2fd50f87
