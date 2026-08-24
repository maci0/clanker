# Bug — A web UI plugin's tab is wired at the end of VIEWS but inserted mid-rail, so arrow-key order scrambles

## TL;DR

- **What failed:** ui/app/core/plugins.js inserts a plugin's rail tab inside its group heading, then does _VIEWS.push(id) and _wireTab(tab, _VIEWS.length - 1). wireTab (ui/app/app.js) moves focus purely by that index, and Home/End take VIEWS[0]/VIEWS[last]. For the eleven built-ins VIEWS is exactly the rail's DOM order; a plugin breaks that, so ArrowUp from a Work-group plugin tab lands on System. Registration order is unstable too: eager plugins register on script load.
- **Impact:** Confirmed. With a Work-group plugin enabled, ArrowUp from its tab lands on System, and `End` selects the last-registered plugin rather than the bottom tab. `aria-owns` had the same fault, so a screen reader read the rail out of order too.
- **Resolution:** Resolved on 2026-08-24. wireTab reads the rail's own DOM order via railOrder() instead of the index it was wired with, and the tablist's aria-owns is rebuilt in rail order rather than appended to. ui/app/app.js, ui/app/core/plugins.js, ui/app/core/plugins.test.mjs.

## Status

Resolved on 2026-08-24. wireTab reads the rail's own DOM order via railOrder() instead of the index it was wired with, and the tablist's aria-owns is rebuilt in rail order rather than appended to. ui/app/app.js, ui/app/core/plugins.js, ui/app/core/plugins.test.mjs.

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

`wireTab` computes its neighbours from the rail's own DOM order, read per
press by a new `railOrder()` over `#rail [role='tab'][data-view]` and filtered
to `VIEWS`. Per press rather than captured, because a plugin's tab can join the
rail long after a built-in tab was wired. The index a tab was wired with is kept
as the fallback for a tab that is not in the rail at all.

`aria-owns` on `.rail-places` is the second half: the Set up group's tabs live
outside the tablist element and are members of it only through that attribute,
so the order it is written in is the order a screen reader reads. Appending each
new id put a Work-group plugin after System. `syncTablistOwns` rebuilds the
whole attribute from the rail's order instead.

## Verification

`ui/app/core/plugins.test.mjs`. `railOrder` and `wireTab` are lifted out of
app.js and run in a `vm` against a DOM stub of the shipped rail, with a `files`
plugin registered into the Work group exactly as `makeViewShell` places it.
ArrowUp lands on Kanban, ArrowDown on Runs, `End` on System, `Home` on Chat; the
tabs either side of the plugin agree with it, and both ends still wrap. A key
the tablist does not own is left alone, which is the control: it passes on both
sides. `aria-owns` is asserted as the full thirteen-id rail order with two
plugins enabled.

Control run against untouched `origin/main`: ArrowUp fails there with
`'system' !== 'kanban'`, which is exactly the symptom this report claimed. Full
`clanker gate` green, twelve of twelve.

## Follow-up

## References

- Investigation: none yet
