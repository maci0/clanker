# REPL TUI feature checklist (the deleted hand-rolled REPL)

**This describes an implementation that no longer exists.** `src/tui/*`'s
input, region, statusbar, palette, approval and term modules, `cmdRepl`, the
pty `tui-test` suite and `util/lineedit.zig` were deleted when the REPL moved
to libvaxis (`src/tui/repl_vaxis.zig`). Only `transcript.zig`, `theme.zig`,
`syntax.zig` and `width.zig` survive, because `clanker run` and the vaxis REPL
render through them.

It is kept as a specification, not a status report: every item below worked,
and most of them do not work in the vaxis REPL yet. `docs/ROADMAP.md` tracks
closing that gap. Read the "test that proves it" column as a record of what the
behaviour was, not as a suite that still runs.

Tracks each target item from the TUI rewrite against the code that
implements it and the test that proves it. See
`docs/ROADMAP.md` for the shipped-feature summary and the design plan for
architecture rationale (fixed-region compositor, why cards are left-bar
style, etc.).

Verification tiers, referenced below:

- **unit** — a `test` block in the named file, runs under `zig build test`.
- **live** — manually driven against the real interactive `clanker repl`
  during development (a real pty via `script`, or the FIFO-paced technique
  needed once printf-blasting raced the raw-mode setup) and visually
  confirmed correct. Not automated.
- **pty** — an automated `zig build tui-test` case in
  `src/tui/testing/demo.zig`, spawning the real binary over a hand-rolled
  pty (`src/tui/testing/pty.zig`). All 5 (4 scripted sessions + `pty.zig`'s
  own `buildArgv` unit test) pass — confirmed via `zig test
  src/tui/testing/demo.zig` directly against the last successfully built
  `zig-out/bin/clanker`. The `zig build tui-test` *step* itself is
  currently blocked: it depends on rebuilding the full binary, and
  `src/improve/engine.zig` (a protected path, untouched by this work) has
  an unrelated in-flight compile error from concurrent work elsewhere.
  Nothing to do here but wait for that file to settle — `zig build test`
  (the fast gate) is unaffected since it never needs to fully compile that
  function.

| # | Feature | Implementing code | Test |
|---|---|---|---|
| 2 | Persistent multiline input box (paste, mid-line wrap, backspace/history all still work) | `src/tui/input.zig` (`wrap`/`frame`), `src/tui/region.zig` (`BottomRegion`), wired via `readLineRaw`/`redrawRegion` in `src/cli.zig` | unit: `input.zig` (7 tests), `region.zig` (6 tests). live: multiline paste, mid-line wrap, live per-keystroke redraw all visually confirmed during Phase 1/2 development. pty: `demo.zig` "Ctrl-C clears the line instead of killing the process" (also proves the raw-mode Ctrl-C fix — see item 5's note on `approval.zig` for the same class of fix). |
| 3 | Status bar (model / session / tokens / budget / activity) | `src/tui/statusbar.zig`, wired via `redrawRegion` | unit: `statusbar.zig` (6 tests). live: confirmed showing live model/session/token data, and live-updating on `/session switch`. |
| 4 | Slash-command palette + Tab autocomplete | `src/tui/palette.zig` (`index`/`complete`/`helpText`), `.tab` key in `src/util/lineedit.zig`, wired via `tryComplete` in `src/cli.zig`; `:help` now generated from the same index instead of a hand-maintained string | unit: `palette.zig` (5 tests), `lineedit.zig` (`.tab` test). live: confirmed real Tab-completion cycling via the FIFO-paced pty technique. pty: `demo.zig` "Tab completes a unique slash command". |
| 5 | Inline approval prompts (re-prompt on bad input, not silent default) | `src/tui/approval.zig` (`ask`), replaces `replAsk`'s raw-stdin read | Not directly unit-tested (real terminal I/O, same tier as `readLineRaw` itself — see `region.zig`/`input.zig`/`lineedit.zig` for the primitives it's built from, which are). Needs a real `ask_user` tool call to exercise live or via pty, deferred for the same no-spend reason as item 1. |
| 6 | In-REPL session resume/switch (`/session switch <id>`) | `replHandleLine` in `src/cli.zig`, consuming `session.loadSession`/`listSessions` (`src/agent/session.zig`) unchanged | live: confirmed both the bad-id error path and a real switch (status bar updated from `repl-<ts>` to the target session id, message count reported). pty: `demo.zig` "an invalid /session switch reports the error and keeps the prompt usable". |
| 7 | Themable ANSI output, `NO_COLOR` support | `src/tui/theme.zig` (`Theme`/`select`), threaded through `transcript.zig`, `statusbar.zig`, `approval.zig`, and the remaining REPL-only literals in `cli.zig` | unit: `theme.zig` (5 tests) + a mono-emits-no-ANSI test in each of `transcript.zig`/`statusbar.zig`. live: `NO_COLOR=1` confirmed to strip every SGR code from a live session while structural cursor-control escapes (needed for the box to render at all) correctly remain. |
| 8 | Resize-safe rendering | `src/tui/term.zig` (`resize_pending`/`installResizeHandler`, SIGWINCH), consumed in `redrawRegion` (`src/cli.zig`) | Not independently unit-testable (signal delivery needs a real OS/tty). Mirrors `std.Progress`'s own SIGWINCH handling pattern. Live verification was inconclusive in this sandbox (its pty allocation proxies through something that doesn't expose a conventional `/dev/pts` device to shell tools like `stty`); `kill -WINCH` was sent directly to validate the handler wiring, with ambiguous results reading back the raw byte stream by hand. **Known gap**: a `demo.zig` case driving `Pty.resize` and asserting the redraw reflows at the new width was not completed this pass. |

## Bonus: WASM plugin surfaces for REPL behavior

Not part of the original 8 target items — added mid-implementation at the
user's request ("repl plugins via wasm also, to manipulate repl behaviour
etc").

| Plugin surface | Implementing code | Demo plugin | Test |
|---|---|---|---|
| `statusline: true` — contribute a status-bar segment | `Registry.statuslineTools` (pre-existing, was unused), `statuslineSegments`/`refreshStatusline` in `src/cli.zig` | `tools/zig/statusline_clock.zig` (ships `enabled: false`) | live: confirmed a real segment (`06:31:43 UTC`) appearing in the status bar end to end. |
| `turn_hook: true` — print a line into the transcript after each turn | `Registry.turnHookTools` (new, mirrors `statuslineTools`), `runTurnHooks` in `src/cli.zig` | `tools/zig/turn_hook_echo.zig` (ships `enabled: false`) | unit: `registry.zig` (descriptor parse + filter/sort tests). Not live-verified — needs a real turn (`a.run()`), which costs real API credits; deferred for the same reason as items 1 and 5 above. |

Both are `internal: true` (required — otherwise the LLM would see them as
callable tools) and therefore exempt from the `/plugins` runtime toggle by
design (`Registry.Tool.toggleable`); trying either means flipping `enabled`
in its manifest, not a `/plugins` command.

## Known gaps / follow-up debt

- Tool-call cards, the approval widget, and the `turn_hook` plugin all need
  a real agent turn to exercise end to end, which this pass deliberately
  avoided triggering (real API spend) both live and in `demo.zig`. A
  follow-up could add one pty case that runs a genuinely free/local task
  (e.g. the `calculator` tool with no network) to close this gap without
  spending on an LLM call.
- Resize has no pty-driven test. `Pty.resize` (`src/tui/testing/pty.zig`)
  exists and is ready for this; the missing piece is a `demo.zig` case and,
  ideally, a more reliable way to observe the post-resize reflow than
  scraping raw escape sequences by hand.
- ~~The piped (non-TTY) REPL fallback loop's own hardcoded ANSI literals~~
  Closed: the fallback loop now writes the themed `repl_prompt` and uses
  `repl_theme.dim`/`reset` for the choice echo, so `NO_COLOR`/`--theme mono`
  strips its SGR codes the same as raw mode. Structural cursor-control
  escapes remain, as everywhere else.
