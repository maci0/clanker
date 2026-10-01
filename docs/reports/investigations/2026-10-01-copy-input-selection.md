# Investigation — Copy fallback selects no input value

## TL;DR

- **Question:** The fallback selects an input node rather than its value. The regression fails against the previous implementation and passes with a focused, selected input.
- **Finding:** Resolved on 2026-10-01. Fixed in 2fd50f87; pre-fix clipboard regressions failed, fixed tests, lint, typecheck and end-to-end tests passed.
- **Resolution:** Resolved on 2026-10-01. Fixed in 2fd50f87; pre-fix clipboard regressions failed, fixed tests, lint, typecheck and end-to-end tests passed.

## Status

Resolved on 2026-10-01. Fixed in 2fd50f87; pre-fix clipboard regressions failed, fixed tests, lint, typecheck and end-to-end tests passed.

## Trigger and scope
The web copy button falls back to a selected input when the Clipboard API is unavailable.

## Evidence
At c8fda468 the fallback passed the empty input node to Range.selectNodeContents. The focused-input and accessible-label regressions failed against that implementation; all four clipboard tests pass at 2fd50f87.

## Hypotheses and tests
Selecting an input node does not select its value. Replacing the range selection with field.focus() and field.select() fixes the regression.

## Finding
The shared copyText fallback selected the wrong browser object.

## Resolution or handoff
Fixed in 2fd50f87. See the [bug](../bugs/2026-10-01-copy-input-selection.md) and [recovery procedure](../../runbooks/copy-input-selection.md).

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: [Copy input selection](../bugs/2026-10-01-copy-input-selection.md)
