# Bug — Corrupt state/webui_plugins.json was swallowed silently

## TL;DR

- **What failed:** The webui_addon guest's loadState turned a parse failure (and any non-NotFound read error) into an empty state with no trace, so every plugin silently read as off. PRD 0012's failure modes require a warn on load. loadState now logs through ck_log at warn, naming the file, what failed, and the error, keeping the empty-enabled-list fallback.
- **Impact:** A hand-edit typo or truncated write turned every web UI plugin off with nothing anywhere saying why; the page state read as a deliberate setting and got debugged in the browser.
- **Resolution:** Resolved on 2026-08-19. loadState warns through ck_log on read/parse failure; verified live over serve with a corrupt and a healthy state file

## Status

Resolved on 2026-08-19. loadState warns through ck_log on read/parse failure; verified live over serve with a corrupt and a healthy state file

## Symptom and impact

With a corrupt `state/webui_plugins.json`, `GET /api/webui/plugins` answers
`ok:true` with every addon disabled and no log line at all. The empty state is
indistinguishable from someone having turned everything off. PRD 0012's
failure-mode table promises "treated as empty enabled-list; warn once on load
(server log / System status)" — the fallback existed, the warn did not.

The PRD's Known issues entry placed the fix beside a `catch WebuiPluginState{}`
in `src/cli.zig`, but that code had since moved: the guest tool
`tools/zig/webui_addon.zig` owns the state file now, and its `loadState`
swallowed both a parse failure and any non-NotFound read error into `.{}`.

## Reproduction

```
echo '{not json' > state/webui_plugins.json
clanker serve --webui-port 40911 &
curl -s http://127.0.0.1:40911/api/webui/plugins
```

Unfixed: the answer lists every addon `enabled:false`; the server log has no
trace. (NotFound stays special: a fresh checkout seeds the default enabled
list and must not warn.)

## Root cause

`loadState` in `tools/zig/webui_addon.zig`: `lib.fsRead` errors other than
NotFound returned `.{}` silently, and `std.json.parseFromSliceLeaky … catch
.{}` did the same for corrupt content.

## Resolution

`loadState` now routes both failure paths through a `warnBadState` helper that
logs via `ck_log` level 2 (`[tool]` warn in the server log), naming the file,
what failed (read vs parse), and the error name. The empty-enabled-list
fallback and the fresh-checkout NotFound seed are unchanged; the next
successful toggle still rewrites a clean file.

## Verification

Live serve on the fixed build, corrupt file:

```
[WARN] … [tool] state/webui_plugins.json failed to parse (SyntaxError);
treating it as an empty enabled-list until the next toggle rewrites it
```

and the API still answers `ok:true` with the addons listed (disabled).
Control with a valid file: zero warn lines.

## Follow-up

None.

## References

- PRD: docs/prds/0012-surface-plugins.md (Known issues, failure modes)
- Investigation: none — straight from the PRD's Known issues entry
