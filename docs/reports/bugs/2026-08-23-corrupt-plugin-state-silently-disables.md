# Bug — corrupt TUI/CLI plugin state silently disabled every plugin

## TL;DR

- **What failed:** loadEnabled in src/tui/slash_plugins.zig and src/cli/cli_plugins.zig swallowed parse failures and non-NotFound read errors into an empty enabled-list with no trace, so a corrupt state file silently turned every surface plugin off. PRD 0012's failure modes promise empty enabled-list plus a warning, and the identical defect was already found and fixed for state/webui_plugins.json. Fixed: both loaders warn, keeping the empty-list fallback; a missing file stays silent.
- **Impact:** A truncated write, a stray edit, or any bytes that fail the JSON parse turned every enabled TUI slash-command plugin and CLI plugin off with no trace anywhere. To the operator that is indistinguishable from never having enabled them: `/mycommand` stops resolving, `clanker mycommand` falls through to Tier 2 or "unknown command", and nothing points at the state file.
- **Resolution:** Resolved on 2026-08-23. Both loaders warn on a corrupt or unreadable state file while keeping the empty enabled-list fallback; a missing file stays silent. Pinned by parseEnabled tests in both modules and verified live: a corrupt state/cli_plugins.json logs the WARN naming the file, removing it removes the warning.

## Status

Resolved on 2026-08-23. Both loaders warn on a corrupt or unreadable state file while keeping the empty enabled-list fallback; a missing file stays silent. Pinned by parseEnabled tests in both modules and verified live: a corrupt state/cli_plugins.json logs the WARN naming the file, removing it removes the warning.

## Symptom and impact

Found while evaluating PRD 0012's Known issues bullet on state-file shapes
(that bullet itself is settled design, not a defect: both loaders implement
the locked enabled-list, default off). The adjacent contract is not met,
though: the PRD's Failure modes table says a corrupt
`state/tui_plugins.json` / `state/cli_plugins.json` gives "empty
enabled-list + warn; no plugin commands dispatched until re-enabled" — and
the Known issues list records the identical defect being found and fixed
for `state/webui_plugins.json` earlier. Both native loaders still had the
silent version.

## Reproduction

```
echo '{not json' > state/cli_plugins.json
clanker <some-enabled-plugin-command>
```

Pre-fix: the command fails as unknown, with no log line about the state
file. Same for the TUI: corrupt `state/tui_plugins.json`, start the REPL,
every plugin slash command is gone, nothing logged.

## Root cause

Both `loadEnabled`s read and parsed with `catch return &.{}`:

```
const raw = std.Io.Dir.cwd().readFileAlloc(io, state_path, ...) catch return &.{};
const st = std.json.parseFromSliceLeaky(EnabledState, ...) catch return &.{};
```

`error.FileNotFound` (the normal everything-off default) and real failures
(corrupt JSON, wrong shape, permission errors, oversize) were folded into
the same silent empty list.

## Resolution

Both loaders now distinguish the cases: a missing file stays silent
(off-by-default is the normal state); any other read error warns naming
the file and the error; a parse failure warns that the file is not valid
state JSON and that every plugin is treated as disabled until the next
successful toggle rewrites a clean file. The empty-list fallback itself is
unchanged, as the PRD requires. The parse step is split into a testable
`parseEnabled` in each module.

## Verification

- Unit: "parseEnabled reads the enabled-list and refuses corrupt bytes" in
  both src/tui/slash_plugins.zig and src/cli/cli_plugins.zig (good shape
  parsed; corrupt bytes and wrong top-level shape → null → warn path).
- Live: with `state/cli_plugins.json` containing `{not json`, a
  `clanker <plugin>` invocation logs the new `[WARN]` line naming the file
  before falling through; removing the file removes the warning.
- src/cli/cli_plugins.zig is now registered in src/main.zig's comptime
  test-root block (it previously had no tests, so it was never listed).

## Follow-up

## References

- PRD 0012 (docs/prds/0012-surface-plugins.md) — Failure modes, Known
  issues (webui twin of this defect, and the updated bullet).
- src/tui/slash_plugins.zig, src/cli/cli_plugins.zig — the loaders.
