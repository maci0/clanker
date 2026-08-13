# PRD — REPL / TUI

## Status

Shipped (libvaxis-based), with known gaps tracked below. Source of truth:
`src/tui/repl_vaxis.zig` (the `vxfw` app). Shared rendering with `clanker
run`: `src/tui/transcript.zig`, `theme.zig`, `syntax.zig`, `width.zig`.
Surface: `clanker repl`.

The REPL this replaces (`src/tui/{input,region,statusbar,palette,approval,
term}.zig`, `cmdRepl`, `util/lineedit.zig`, the pty `tui-test` suite — about
1,100 lines of `cli.zig` plus eight files) was deleted outright when the
migration landed: full replacement, not additive, the user's explicit call
after the tradeoff below was raised and weighed.

## Problem

Interactive use needs a persistent line-editing surface — history, resizing,
live status, tool-call visibility, session switching, themed output — without
pulling network calls onto the render thread. The prior implementation
hand-rolled every layer directly against the terminal: raw-mode input, a
wrapped multiline box, a SIGWINCH self-pipe, inline approval prompts. That
worked, but every primitive it reimplemented — key decode, resize delivery,
cell diffing — is something a maintained library already solves, and clanker
had no existing terminal library to lean on. The choice was genuinely
"hand-roll vs. adopt," not "improve what's there," and `agave` (a sibling Zig
project) had already tried a TUI library and walked it back — a precedent
raised and weighed before the user chose to adopt anyway.

## Goals

1. A persistent, resizable REPL session running a real `Agent.run` without
   blocking the UI thread.
2. Live status while the LLM streams or a tool executes.
3. Session persistence: resume a saved conversation with model, token/cost
   and context-budget visibility in the status bar.
4. Themed output consistent with `clanker run`'s ANSI theme.
5. Untrusted text (LLM output, tool results) never reaches the terminal as
   raw control bytes.

## Non-goals

- Reproducing the deleted REPL's exact interaction surface before the
  Acceptance criteria below says so. The migration deliberately accepted a
  narrower feature set in exchange for maintained primitives; closing each
  gap is tracked work, not a regression to apologize for.
- A GUI or non-terminal renderer.

## Design

**Why libvaxis over hand-rolled.** `github.com/rockorager/libvaxis` is
version-compatible (`minimum_zig_version = "0.16.0"`, matches exactly) and
has two API layers: a low-level immediate-mode `Window`/`Cell` grid (like a
thin ncurses) and `vxfw`, a retained-widget app framework (`ScrollView`,
`ListView`, `TextField`, `Spinner`, `Border`, `FlexRow`/`FlexColumn`,
`Table`). `vxfw` is the layer in use — its widgets map closely enough to what
the old REPL had that it's a port, not a from-scratch rebuild.

**The real cost: alt-screen, not a library swap.** `vxfw.App.run` always
calls `vx.enterAltScreen(...)`, unconditionally — no opt-out at this layer.
The prior REPL was a normal scrolling terminal session: transcript text
became real terminal/tmux scrollback, copy-pastable and searchable the
ordinary way, with only a small region (status bar + input box) redrawn in
place. The vaxis REPL redraws the *entire* transcript into an alternate-screen
buffer every frame, like `vim` or `htop` — native scrollback for old messages
is gone; paging back into history is an in-app concern (manual scrollback,
shipped, see Acceptance criteria). This was seen and accepted live, not
approved on paper alone, before the rest of the migration proceeded.

**Threading and idle cost.** A background thread runs the real `Agent.run`
(LLM calls block that thread, not the UI); a 50ms tick streams tokens live
but only runs while a turn is in flight — idle, the app is purely
event-driven, no busy loop. `vxfw.App` delivers SIGWINCH through its own
event loop, so the hand-rolled self-pipe fix the old `term.zig` needed has no
equivalent here and was deleted, not ported.

**Shared rendering with `clanker run`.** `transcript.zig`, `theme.zig`,
`syntax.zig`, `width.zig` survived the old REPL's deletion specifically
because both `clanker run` and the vaxis REPL render through them — one
markdown streamer, one theme mapping, one width table, not two.

**Control stripping (CWE-150).** Everything rendered here is text clanker
didn't generate itself — LLM output, tool results, clipboard contents. Every
such path goes through `sanitize.zig` (`clean`, a wrapper over
`sanitizeAlloc`), which drops C0 controls except `\n`/`\t`, DEL, and the
UTF-8-encoded C1 range `U+0080..U+009F`, so a raw ESC — or a `\xc2\x9b` that
a C1-decoding terminal reads as CSI — can't inject an escape sequence. The
common case (no control bytes) is alloc-free: it scans first and only copies
if it finds something to drop. On an allocation failure the text is dropped,
never passed through: rendering unsanitized bytes is the one outcome the
wrapper exists to prevent, so it is not an acceptable fallback for it.

The seam matters more than the predicate. Stripping used to happen at each
call site, which meant it could be — and was — missed at several: `onToken`
stripped each streamed delta, but `finishTurn` renders the provider's whole
`message.content` whenever there is one (and `chatStream` always assembles
one), displacing the sanitized streamed copy with text that had never been
stripped. `runToolJson`'s `text`, the provider's `err_detail`, and OSC 52
clipboard payloads were never stripped either. All of them now are, and the
answer path strips inside `appendAnswerLines` — the single function that
turns a turn's prose into transcript — rather than trusting each caller.

How much of that was reachable depended on the draw branch, which is the
part worth remembering. Answer lines render through `writeWrappedSegments`,
which skips graphemes of display width 0; a control byte measures 0, so ESC
in model prose was being swallowed by a *wrapping* guard rather than by any
security control. `writeWrapped`, the branch every dim line takes, has no
such guard. The two untrusted strings that land there — `err_detail` and
internal-tool `text` — were therefore live injections rather than
theoretical ones. Sanitizing at the seam makes the guarantee independent of
which branch a line happens to take.

A local `stripControls` that reused only `sanitize.isControl` — catching
single bytes but not the two-byte C1 sequences — was deleted as part of this,
since `sanitize.zig` already documents itself as owning the one definition.
That gap applied even to paths described as already stripped, `!` escape
output among them.

**Repainting is opt-in, so one seam owns it.** `vxfw` redraws when an event
handler sets `ctx.redraw` and not otherwise. A submitted line fans out to a
dozen places that append to `lines` — the generated `/help`, each `cmd_*`
tool's output, every command's usage block, the unknown-command notice, the
whole `!` escape path — and asking each to remember the flag does not work:
only `/theme` and `/compare` ever did, so everything else wrote into a buffer
nothing repainted and surfaced later, attached to whatever unrelated
keystroke came next. (Agent tasks looked fine only because `submitTask`
schedules a `ctx.tick`, which redraws for its own reasons.) The Enter handler
now sets it once for every path through `submit`, which is why none of those
call sites carry it.

**Closing the remaining gaps — widget mapping.** Most open items below have a
specific `vxfw` shape, not an open-ended "figure it out":

| Gap | `vxfw` mechanism |
|---|---|
| Slash-command search (fuzzy palette) | The same `cmd_*` internal-tool catalog the web UI's palette drew from; needs a modal keystroke-owning loop like `/model`'s (`picker_open`/`handlePickerKey`) reused for command lookup, not a new one. Tab-complete's prefix match over `command_registry` already shipped (see Acceptance) and is a separate, narrower mechanism |
| Inline `ask_user`/confirm-before-write | `/model`'s modal machinery again — a prompt that owns keystrokes until answered, wired to `AskFn`/`confirm_fn` the same way the web UI's ask bridge is |
| Real markdown outside fences | `transcript.zig`'s `MdStream` already does this for `clanker run`; wire its output into a `RichText`/`Text` widget instead of a raw `Io.Writer` |
| Multi-line input | `vxfw.TextField` has no multi-line mode; needs either a custom widget or accepting Shift+Enter has no vaxis primitive to hook |
| Plan mode | `Agent.plan_mode` and the `needsConfirm` gate already exist (web UI drives both); needs a REPL-side toggle key and system-prompt block, no new backend |
| Visible stats/compaction | **Shipped.** `src/tui/stats.zig` is the one formatter; the status bar gained the web UI's context meter and the transcript gained a per-turn line and two compaction notices |

## Failure modes

| Condition | Behaviour |
|---|---|
| SIGWINCH mid-render | Handled by `vxfw.App`'s own event loop; no self-pipe, no dropped resize |
| A command that only prints (`/help`, `/status`, `!`) | Repaints on the Enter that ran it, not on the next unrelated keystroke |
| Ctrl-C, idle prompt | Quits the REPL (`ctx.quit = true`) |
| Ctrl-C, mid-stream | Sets the same `stop_flag` `client.chatStream` already checks |
| `ask_user` invoked here | No `ask_fn` is wired; falls back to the same "nobody attached" default (`not_found`) a headless run gets. No prompt-rendering path exists yet (tracked below) |
| `confirm_writes = "always"` invoked here | No `confirm_fn` is wired either, so write-capable tool calls run **ungated**, not declined. A one-line warning prints once at startup so the operator isn't left believing they're protected |
| Control bytes in LLM/tool output | Stripped before render, per Design. Covers the streamed deltas, the provider's final `message.content`, its `err_detail` on a failed turn, internal `cmd_*` tool `text`, `!` escape output, and clipboard payloads |
| History exceeds visible height | PgUp/PgDn/Home/End page it (manual scrollback, shipped) |

## Acceptance criteria

Shipped:

- [x] Real `Agent.run` on a background thread; streamed tokens via a 50ms
      tick that only runs while a turn is in flight
- [x] Tool-call/result status lines rendered as bordered left-bar cards
      (`transcript.zig` card helpers), one card per tool batch
- [x] Status bar with an animated spinner
- [x] First-run hint when the transcript is empty ("Start with a task...",
      "Try /model to switch models, /help for commands, or type anything
      to begin.")
- [x] `Ctrl-C` (idle quits the REPL; mid-stream sets `stop_flag`)
- [x] Quit commands (`/quit`, `/exit`, `/q`, bare `exit`/`quit`)
- [x] SIGWINCH handled natively by `vxfw.App`
- [x] Untrusted text control-stripped before rendering (CWE-150)
- [x] `/model` fuzzy picker (grouped by provider, context window + $/1M
      shown inline, mid-conversation switch). The list shows eight rows and
      scrolls: the window follows the selection (`pickerWindowStart`, derived
      from the selection each frame rather than carried as a second piece of
      state), with an `n/total` marker on the guide row once anything is off
      screen. It previously indexed the list by screen row, so only the first
      eight entries were ever drawn while Up/Down walked the selection across
      the whole list — past the eighth match the highlight vanished and Enter
      committed to a row that had never been on screen.
- [x] `/help` / `?`
- [x] Flag wiring
- [x] Session persistence / resume
- [x] Every command (not just quit/`/model`/`/help`) dispatches through
      `command_registry`; `printHelp` is generated from it, not
      hand-maintained prose
- [x] Tab-complete over `command_registry` (unique match completes the
      line, several complete to their shared prefix and list the rest)
- [x] Manual scrollback (PgUp/PgDn, Home/End)
- [x] Bottom-anchored transcript: at rest and while scrolled back the visible
      block hugs the input (chat-client layout); streaming still flows top-down
      (`tailWindow`/`lineRows`, bottom-align offset in `draw`)
- [x] Scrollbar in the rightmost column when the transcript overflows, thumb
      tracking the visible window (`drawScrollbar`)
- [x] Prompt echo and status line coloured (accent brand/model, green idle
      phase, the user's `clanker>` line in bold prompt-green)
- [x] Multi-line transcript output renders one row per line (was collapsing
      onto one row: `/help` and completed replies; `row += 1` per Line)
- [x] Per-turn stats line and visible compaction (`src/tui/stats.zig`,
      shared with `clanker run`'s stderr footer): tokens in/out, wall time,
      tok/s, cache hit rate, cost (omitted for an unpriced model rather than
      shown as `$0.00`), and a `ctx used/window (%)` meter in both the turn
      line and the status bar. `session.compactMessages` reports what it
      dropped; `Agent.maybeCompactMessages` is reported from the summary
      message it leaves behind

Open (roughly most-noticed first; the bar is grok / kimi / opencode's CLIs):

- [ ] **Inline `ask_user` / confirm-before-write prompt UI.** The biggest gap:
      a run that calls `ask_user`, or `agent.confirm_writes = "always"`, has no
      prompt-rendering path here, so the question is silently declined / the
      write runs ungated (`repl_vaxis.zig` startup warning says so). The
      `/model` picker's modal (`picker_open`/`handlePickerKey`) is the shape to
      reuse, not a new mechanism.
- [ ] **Graceful iteration-limit landing.** Hitting `agent.max_iterations`
      returns `error.MaxIterationsExceeded` and the turn renders `[error: ...]`,
      discarding every tool round's work with no partial answer. Default raised
      24 -> 50, but the REPL should surface partial progress and offer to
      continue (append "keep going") rather than erroring, the way a coding CLI
      does. (Config bump: `config.zig`.)
- [ ] **Real markdown outside fenced code.** Only fences get styled
      (`syntax.zig`); bold/italic/inline-code/headings/bullets render as plain
      text, unlike `clanker run`'s `MdStream` and every CLI above.
- [ ] **Multi-line input** (Shift+Enter or a heredoc paste mode). `vxfw.TextField`
      is single-line; Enter always submits.
- [ ] **Transcript search.** Scrollback paging exists; `/`-to-search within it
      does not (grok/opencode both have it).
- [ ] **Slash-command fuzzy palette.** Tab-complete is prefix-only; a `/model`-
      style fuzzy picker over `command_registry` would match mid-word.
- [ ] **Image / multimodal input.** The web UI has an attachment path (webui
      1.3); this REPL has no route for a task that needs one.
- [ ] **Plan mode toggle.** `Agent.plan_mode` exists and the web UI toggles it
      (webui 2.2); nothing here sets it, so no propose-then-apply flow.
- [x] **Inline `!shell` escape.** grok/kimi/opencode (and Pi) run a shell line
      with a `!` prefix without leaving the loop. Shipped: `submit()`
      intercepts a leading `!` before `parseCommand` (`parseShellEscape`),
      `splitShellArgs` builds one fixed argv, and `host.execUnderPolicy` runs
      it past the same `ck_exec` gate a tool goes through — not a shell, so no
      pipes, globs, redirections or `$VAR`. The allowlist is the union of the
      registry's `exec_allow` plus `agent.repl_exec_allow`; bare `!` prints it.
- [ ] **Theme without an env var.** Colour (the RGB palettes) only lights up
      when `CLANKER_THEME` is set; the default 16-colour theme is bold-only. A
      `/theme` command or truecolor autodetection would surface it.

## Failure modes (stats)

| Condition | Behaviour |
|---|---|
| Model has no pricing in the catalogue | Cost segment omitted from the turn line and no session cost in the status bar. `$0.0000` would read as "this model is free", which is a different claim from "nobody wrote down what it charges" |
| Provider reported no cache accounting | `cache` segment omitted rather than shown as 0% |
| `context_window` unset for the active model | Context meter omitted from both the turn line and the status bar |
| Turn failed before reaching the provider | No turn line at all, rather than a row of zeroes |
| Turn hit `max_iterations` / the token budget | Turn line still printed: the run spent real tokens and real money whether or not it answered |

## Open questions / future work

- Order of the open items: the ask-bridge/confirm-write gap is the most
  surprising one to a user coming from the web UI, since `agent.confirm_writes
  = "always"` is documented as covering interactive REPL sessions but has no
  render path here yet.
- **`Agent.on_compact` hook.** Mid-turn compaction is currently *detected*
  rather than reported: `Agent.maybeCompactMessages` logs and moves on, so
  `stats.summaryState` recognises the summary message it left behind by its
  two placeholder prefixes and diffs that against a baseline taken at submit.
  It works and is unit-tested, but it couples the REPL to loop.zig's wording,
  and a user message opening with the same prefix would be miscounted. A
  one-field `on_compact` hook on `Agent`, fired next to the existing
  `on_tool_call`/`on_todos` hooks, would retire the scan and let the web UI
  surface the same event on `/api/run`'s `\x01` channel.
