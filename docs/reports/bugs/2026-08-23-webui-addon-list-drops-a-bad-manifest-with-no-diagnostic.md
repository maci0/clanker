# Bug — A plugin with one typo in capabilities vanishes from the list with nothing to read, and group is never checked

## TL;DR

- **What failed:** actionList (tools/zig/webui_addon.zig) emits a diagnostic description for a plugin.json that will not parse, then three lines later does capabilitiesRejected(...) |_| continue, dropping a present-but-slightly-wrong manifest silently; its assets 404 too, since listedEnabled resolves off the same answer. validGroup is called in create and put but never in list, so a manifest with group Setup is listed verbatim, matches no rail heading, and the tab lands unstyled outside the nav list.
- **Impact:** An addon with one typo in `capabilities` vanished from System with nothing to read, and its assets 404ed; a manifest with an unknown group put its tab outside the rail's nav list, unstyled.
- **Resolution:** Fixed. `actionList` lists a capabilities-rejected manifest with the rejection as its description (disabled — a typo is still not a grant), and validates `group` in `list` too, falling back to Watch with a note in the description.

## Status

Resolved.

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

Fixed in `actionList` (`tools/zig/webui_addon.zig`): a capabilities-rejected
manifest is listed with `plugin.json rejected: <why>` as its description and
`enabled: false` (a typo is not a grant, so its assets keep 404ing), matching
the existing treatment of an unparseable manifest; and `validGroup` now runs in
`list` too, falling an unknown group back to Watch with a note appended to the
description naming the group that matched no rail heading.

## Verification

`src/sandbox/runtime.zig` test "webui_addon list surfaces a rejected manifest
and falls an unknown group back to Watch": a `capabilities: ["gett"]` manifest
comes back listed with the rejection to read, and a `group: "Setup"` manifest
comes back under Watch with the note, the raw group absent from the answer.

## Follow-up

## References

- Investigation: none yet
