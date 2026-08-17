# Missing clanker tool — The REPL had no /rfc although clanker rfc exists

## TL;DR

- **Missing tool:** clanker rfc has a full CLI surface, and the REPL's rule is that a slash command sharing a CLI verb's name does what the verb does (/research reuses research_cmd.run). /rfc was absent from the REPL command registry, so the RFC store was unreachable from the TUI. Wired /rfc through a new rfc_cmd.run, the same split research/command.zig uses.
- **Finding:** Resolved on 2026-08-17. Wired /rfc through rfc_cmd.run in src/tui/repl.zig; verified by zig build test (new /rfc parse test) and clanker gate.
- **Resolution:** Resolved on 2026-08-17. Wired /rfc through rfc_cmd.run in src/tui/repl.zig; verified by zig build test (new /rfc parse test) and clanker gate.

## Status

Resolved on 2026-08-17. Wired /rfc through rfc_cmd.run in src/tui/repl.zig; verified by zig build test (new /rfc parse test) and clanker gate.

## What is missing

## Why it is basic

## Ad-hoc fallback used

## Proposed shape

## References

- Related record: none yet
## Evidence

- Before the change, `command_registry` in `src/tui/repl.zig` had no `/rfc` row (checked with `grep -n rfc src/tui/repl.zig`); the only record store with a slash command was `/research`.
- `src/rfc/command.zig` exposed only `cmd`, which prints to stdout through `init.io`. `src/research/command.zig` splits the same surface into `run` (returns the rendered text) and `cmd` (prints it), and the REPL's `/research` calls `research_cmd.run` and folds the text into the transcript — so the missing piece for `/rfc` was that split plus the registry row.

## Resolution

- `src/rfc/command.zig`: each subcommand now returns its rendered text; `pub fn run` dispatches and `cmd` prints `run`'s result. Renderers and the tool seam are unchanged, so `clanker rfc` output is byte-identical.
- `src/tui/repl.zig`: `/rfc <sub> [args]` added to `command_registry` with a `.rfc` action; `runRfcCommand` tokenizes via `splitCommandLine` into `rfc_cmd.Options` and calls `rfc_cmd.run` with a callback that loads the `rfc` guest through `runtime.loadNamedTool` — one implementation across both surfaces.
- The inline `/` preview and command palette derive from `command_registry`, so `/rfc` appears there with no further wiring.

## Remaining gap

Of the five record stores, `/reports`, `/adr` and `/prd` still have no slash command in `command_registry` (checked the same way, 2026-08-17). None of their command modules has the run/cmd split — `reports/command.zig`, `adr/command.zig` and `prd/command.zig` each expose only `cmd` (checked with grep, 2026-08-17) — so each needs the same refactor before its slash command can exist.

## Verification

`zig build test`: 297/297 steps, 1513 passed, 0 failed, 11 skipped, including the new `/rfc` parse test in `repl.zig`.
## Also observed

The `REPL slash commands` table in `docs/README.md` predates several registry entries: before this change it listed neither `/research`, `/websearch`, `/plan`, `/preset`, `/effort`, `/search` nor `/attach` (checked against `command_registry` in `src/tui/repl.zig`, 2026-08-17). This change adds the `/research` and `/rfc` rows; the other missing rows were left as found.
## Issue encountered while verifying: two pty e2e tests fail on the untouched base

`zig build e2e` fails 2 of 27 in this checkout's worktree: `pty_resize_test` and `pty_preview_test`, both at `pty_mod.answerQueries` — the spawned REPL's vaxis capability queries (sixel geometry, then DA1) never arrive within the ~3s answer window. Reproduced three times on 2026-08-17, including once with the /rfc change fully stashed (`git stash`, clean origin/main tree), so it is not caused by this change. The other 25 e2e tests pass, including `rfc create then list shows the decision`, which exercises the refactored `rfc_cmd.run` path. Environment: headless agent session on cachyos, Linux 7.1.5-1; not yet reproduced on an interactive terminal, and the cause was not traced further.