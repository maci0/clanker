# Bug — A web UI plugin's tab is wired at the end of VIEWS but inserted mid-rail, so arrow-key order scrambles

## TL;DR

- **What failed:** ui/app/core/plugins.js inserts a plugin's rail tab inside its group heading, then does _VIEWS.push(id) and _wireTab(tab, _VIEWS.length - 1). wireTab (ui/app/app.js) moves focus purely by that index, and Home/End take VIEWS[0]/VIEWS[last]. For the eleven built-ins VIEWS is exactly the rail's DOM order; a plugin breaks that, so ArrowUp from a Work-group plugin tab lands on System. Registration order is unstable too: eager plugins register on script load.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

With any plugin enabled, roving-tabindex navigation on the rail no longer
follows the rail. ArrowUp from a plugin tab sitting third in the rail lands on
the bottom tab; `End` selects the last-registered plugin rather than the bottom
one. It breaks the WAI-ARIA tabs pattern the rail otherwise implements, and this
PRD asks for a plugin tab to be indistinguishable from a built-in view.

## Reproduction

Read from the source. Enable `files` (group `Work`, so it sits high in the
rail), focus its tab, press ArrowUp.

## Root cause

`makeViewShell` appends the tab inside its group heading, so its DOM position is
correct. Registration then does `_VIEWS.push(id)` and
`_wireTab(tab, _VIEWS.length - 1)`, and `wireTab` (`ui/app/app.js`) computes the
next tab as `VIEWS[(i + step + VIEWS.length) % VIEWS.length]`. For the eleven
built-ins `VIEWS` happens to be exactly the rail order, so the index has always
been a stand-in for DOM position; a plugin is the first thing to separate them.
Registration order is not stable either, since `eager` plugins register on
script load and deferred shells are built synchronously in `loadPluginAssets`.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
