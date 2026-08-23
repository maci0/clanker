# Bug — A plugin with one typo in capabilities vanishes from the list with nothing to read, and group is never checked

## TL;DR

- **What failed:** actionList (tools/zig/webui_addon.zig) emits a diagnostic description for a plugin.json that will not parse, then three lines later does capabilitiesRejected(...) |_| continue, dropping a present-but-slightly-wrong manifest silently; its assets 404 too, since listedEnabled resolves off the same answer. validGroup is called in create and put but never in list, so a manifest with group Setup is listed verbatim, matches no rail heading, and the tab lands unstyled outside the nav list.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

A plugin with one typo in `capabilities` disappears from System with nothing to
read, and its `app.js` and `app.css` 404 even if the operator had enabled it
before, because `listedEnabled` resolves on/off from the same list answer. A
manifest with a group outside `Work`/`Watch`/`Set up` is listed, and its tab
lands as a bare `<button role="tab">` directly inside the `<nav role="tablist">`
rather than inside a nav list item, so it renders unstyled.

## Reproduction

Read from the source. Add `"capabilities": ["gett"]` to any plugin.json and
reload System; add `"group": "Setup"` for the second case.

## Root cause

`actionList` (`tools/zig/webui_addon.zig`) builds a diagnostic row for a
`plugin.json` that will not parse, then three lines later does
`if (logic.capabilitiesRejected(m.capabilities)) |_| continue;` with no row and
no log. `logic.validGroup` is enforced at the `create` and `put` call sites and
never in `list`, which just does `if (m.group.len > 0) m.group else "Watch"`.
`makeViewShell` falls back to `document.querySelector(".rail-nav").appendChild`
when no heading matches, which is the unstyled placement.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
