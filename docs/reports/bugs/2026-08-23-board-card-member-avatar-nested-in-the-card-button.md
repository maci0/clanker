# Bug — A board card's member avatar is a control inside the card button, and picking a member reopens the picker

## TL;DR

- **What failed:** cardNode (ui/app/features/board.js) builds the assignee avatar as a span with role=button inside the card <button>, and appends the whole member picker into that span. role=button children are presentational, so avatar and picker are invisible to the accessibility tree; and a picker item's click bubbles to the avatar's own listener, which stops propagation and reopens the picker. Read from the source, not observed: no headless browser on this machine.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-24. Fixed: cardMemberControl() in ui/app/features/board.js builds a real button in the card's <li>, sibling of the card button, with the picker beside it. The avatar left in the card is aria-hidden scenery holding the row open. Also fixes a third consequence the report missed: .card is overflow:hidden and was the popup's containing block, so the picker was clipped. Five new tests in board-card.test.mjs drive the real memberPicker; 6 of 10 red before. Gate: all twelve PASS.

## Status

Resolved on 2026-08-24. Fixed: cardMemberControl() in ui/app/features/board.js builds a real button in the card's <li>, sibling of the card button, with the picker beside it. The avatar left in the card is aria-hidden scenery holding the row open. Also fixes a third consequence the report missed: .card is overflow:hidden and was the popup's containing block, so the picker was clipped. Five new tests in board-card.test.mjs drive the real memberPicker; 6 of 10 red before. Gate: all twelve PASS.

## Symptom and impact

Two effects. A screen reader user cannot reach the avatar or any member in the
picker it opens, because `role=button` makes its children presentational, so
reassigning from the board is mouse-only. And picking a member reopens the
picker instead of closing it.

## Reproduction

Read from the source; not observed live, because there is no headless browser on
this machine and the board needs a rendered page. On a board with an assigned
card: click the avatar, then click a name in the popup.

## Root cause

`cardNode` (`ui/app/features/board.js`) builds the avatar as
`<span role="button" tabindex="0">` inside the card `<button>` and
`openMemberPopup` appends `memberPicker(c, false)` into that same span. The
picker items call `postBoard` with no `stopPropagation`, so the click bubbles to
the avatar listener, which stops propagation there and calls `openMemberPopup`
again. The sidebar copy of the same picker is a sibling of its button, not a
child, which is why only the card avatar shows it. The nesting is the deeper
problem: it needs the card to stop being a `<button>`, or the avatar to stop
being a control.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
