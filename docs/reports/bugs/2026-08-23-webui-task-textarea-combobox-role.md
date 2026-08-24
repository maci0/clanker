# Bug — The composer textarea carries role=combobox, which ARIA does not allow on a textarea

## TL;DR

- **What failed:** ui/app/index.html declares #task as a <textarea> with role=combobox. ARIA allows combobox on an input, not on a textarea, whose implicit role is textbox with aria-multiline; axe-core reported it as aria-allowed-role in the 2026-08-12 sweep and it is still there. Not a line change: the role has to move to a wrapper while #task stays the textbox, and all four list renderers plus hidePromptList set aria-expanded and aria-activedescendant on el.task, so every one moves in the same change.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-24. Fixed: the role moved to a new #task-combobox wrapper in ui/app/index.html which DOM-contains both the textarea and the listbox; #task is a plain textarea again and keeps aria-autocomplete/aria-controls/aria-activedescendant (ARIA 1.1 shape). All four renderers plus hidePromptList in ui/app/app.js go through one setPromptListOpen(). New structural + guard tests in ui/app/composer-suggest.test.mjs, both red on the unmodified source. Gate: all twelve checks PASS.

## Status

Resolved on 2026-08-24. Fixed: the role moved to a new #task-combobox wrapper in ui/app/index.html which DOM-contains both the textarea and the listbox; #task is a plain textarea again and keeps aria-autocomplete/aria-controls/aria-activedescendant (ARIA 1.1 shape). All four renderers plus hidePromptList in ui/app/app.js go through one setPromptListOpen(). New structural + guard tests in ui/app/composer-suggest.test.mjs, both red on the unmodified source. Gate: all twelve checks PASS.

## Symptom and impact

axe-core 4.13 reports `aria-allowed-role` (minor) on `#task`. Impact is
unmeasured: a field announced as a combobox is not announced as multi-line, and
what an AT does with a role the spec does not allow on the element is up to the
AT rather than specified.

## Reproduction

`ui/app/index.html`: `<textarea id="task" ... role="combobox">`. Any axe run
over the chat view reports it; the source read is enough on its own.

## Root cause

ARIA allows `combobox` on an `input`, not on a `textarea`, whose implicit role
is `textbox` with `aria-multiline`. The composer wants a multi-line textbox with
a popup, which is the ARIA 1.1 shape: the role belongs on a wrapper that owns
`aria-expanded`/`aria-controls`, with the textarea inside carrying
`aria-autocomplete`. Moving it is not a one-line change because
`renderPromptList`, `renderSlashList`, `renderFileMentionList`,
`renderKbMentionList` and `hidePromptList` all set `aria-expanded` and
`aria-activedescendant` on `el.task` today.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
