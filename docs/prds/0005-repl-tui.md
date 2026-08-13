# PRD — REPL / TUI

## Status

Shipped (libvaxis-based), with known gaps tracked below. Source of truth:
`src/tui/repl_vaxis.zig` (the `vxfw` app). Shared rendering with `clanker
run`: `src/tui/transcript.zig`, `theme.zig`, `syntax.zig`, `width.zig`.
Surface: `clanker repl`.

**Critical gap:** `ask_user` and `confirm_writes=always` are ungated in the
REPL. No `ask_fn` / `confirm_fn` is wired, so questions fall through to the
headless "nobody attached" default and write-capable tools run without a
prompt. A one-line startup warning says so; that is not a gate.

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

**A modal has to hold focus to be modal.** `vxfw` delivers a key press to the
focused widget, and the composer has held focus since `.init`.
`vxfw.TextField` consumes every printable key, so the root Model's
`handlePickerKey` only ever received the keys the field ignores — arrows,
Enter, Escape. The `/model` and `/theme` query line was therefore undrawable
into: typed characters went to the composer *behind* the modal, and the
fuzzy filter both pickers advertise was reachable only through a seed
argument (`/model kimi`). Opening a picker now moves focus to the Model and
closing it hands focus back, which is what makes the query line real.

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

| Gap / feature | Status | `vxfw` mechanism / notes |
|---|---|---|
| Slash-command fuzzy palette (Ctrl-P) | **Shipped** | Third `PickerKind` over `command_registry`, same modal as `/model`/`/theme`; Tab-complete remains a separate prefix match |
| Transcript search (Ctrl-R) | **Shipped** | Incremental case-insensitive search over `lines`; drives `view_end` like paging |
| Line-level markdown outside fences | **Shipped** | `mdLineSegments`: bold/italic/code/headings/bullets on completed + live stream |
| Multi-line markdown constructs | **Gap** | Tables, block quotes, nested/ordered lists, setext headings still unstyled; `clanker run`'s `MdStream` stays richer |
| Inline `ask_user`/confirm-before-write | **Gap (critical)** | Reuse `/model`'s modal (`picker_open`/`handlePickerKey`) wired to `AskFn`/`confirm_fn`; today ungated |
| Multi-line input | **Gap** | `vxfw.TextField` has no multi-line mode; Shift+Enter has no vaxis primitive to hook |
| Plan mode | **Gap** | `Agent.plan_mode` + `needsConfirm` exist (web UI); needs a REPL toggle |
| Visible stats/compaction | **Shipped** | `src/tui/stats.zig`; status-bar context meter + per-turn line + compaction notices |

## Failure modes

| Condition | Behaviour |
|---|---|
| SIGWINCH mid-render | Handled by `vxfw.App`'s own event loop; no self-pipe, no dropped resize |
| A command that only prints (`/help`, `/status`, `!`) | Repaints on the Enter that ran it, not on the next unrelated keystroke |
| Enter on a blank or whitespace-only line | Clears the composer and does nothing. It used to reach `submitTask` and spend a real turn on an empty prompt (`isBlankSubmission`) |
| Ctrl-C, idle prompt | Quits the REPL (`ctx.quit = true`) |
| Ctrl-C, mid-stream | Sets the same `stop_flag` `client.chatStream` already checks |
| `ask_user` invoked here | No `ask_fn` is wired; falls back to the same "nobody attached" default (`not_found`) a headless run gets. No prompt-rendering path exists yet (tracked below) |
| `confirm_writes = "always"` invoked here | No `confirm_fn` is wired either, so write-capable tool calls run **ungated**, not declined. A one-line warning prints once at startup so the operator isn't left believing they're protected. That warning is emitted *before* `log.setLevel(.error_)`, which is deliberate: the clamp exists to keep stray stderr off vaxis's alt screen, so it belongs immediately before `app.run`, not at the top of the command. Raised at the top it swallowed this warning (logged at `.warn`) outright, along with config parse warnings and `--session` id complaints |
| Session file corrupt / unreadable on resume (`--session` / `--continue`) | `loadSession` errors other than `FileNotFound` abort REPL startup; the corrupt file is left untouched |
| CJK / fullwidth text in a rendered line | Occupies two columns, wraps whole rather than across the edge, and the row it lands on matches what `lineRows` reserved (`nextCell`) |
| Decomposed text (base + combining mark) | One cell carrying both codepoints, so the accent sits on its letter instead of pushing the line right |
| Control bytes in LLM/tool output | Stripped before render, per Design. Covers the streamed deltas, the provider's final `message.content`, its `err_detail` on a failed turn, internal `cmd_*` tool `text`, `!` escape output, and clipboard payloads |
| History exceeds visible height | PgUp/PgDn/Home/End page it (manual scrollback, shipped); the mouse wheel nudges it three lines a notch; Ctrl-R searches it |
| Mouse wheel | Scrolls the transcript. `vxfw.App.run` enables mouse reporting unconditionally, which takes the terminal's own wheel handling away, so this is owed rather than optional — the same debt that already bought drag-select and OSC 52 copy |
| A modal is open (picker or search) | It owns the keyboard, tested before the scrollback bindings. Those claim Escape whenever `view_end` is set, and jumping to a search hit always sets it, so a modal tested after them would never see its own cancel key |
| A modal is drawn over the transcript | Its interior is blanked first (`clearBoxInterior`); `drawBox` draws only a border, so the text underneath used to show through the gaps |
| Model has no pricing in the catalogue | Cost segment omitted from the turn line and no session cost in the status bar. `$0.0000` would read as "this model is free", which is a different claim from "nobody wrote down what it charges" |
| Provider reported no cache accounting | `cache` segment omitted rather than shown as 0% |
| `context_window` unset for the active model | Context meter omitted from both the turn line and the status bar |
| Turn failed before reaching the provider | No turn line at all, rather than a row of zeroes |
| Turn hit `max_iterations` / the token budget | Turn line still printed: the run spent real tokens and real money whether or not it answered |

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
      (`tailWindow`/`lineRows`, bottom-align offset in `draw`). One window
      computation serves every case. Scrolling back *during* a stream used to
      take a branch of its own that called `tailStart` — a one-line-per-row
      guess that ignores wrapping — and top-aligned the result, so the same
      anchor showed one window while a turn streamed and a different one the
      moment it ended: wrapped lines were miscounted and the block jumped from
      the top of the region to the bottom. That branch was also redundant.
      `reserved` is only non-zero when the stream is at the tail, which
      requires `view_end == null`, so in the frozen case the general path was
      already computing what the special case was reaching for, only
      wrap-accurately. `tailStart` is gone with it.
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
- [x] **Transcript search.** Shipped on **Ctrl-R**: an incremental,
      case-insensitive substring search over `lines`, Up/Down (or
      Ctrl-N/Ctrl-P) stepping hits with wraparound, Enter leaving the view on
      the match and Escape putting the reader back where they started. The
      current hit is drawn reversed and the bar shows `n/total`, or
      `no match`.

      Not `/` as this item originally guessed: a leading `/` is how this REPL
      spells a command, so `/status` would have to mean both "run it" and
      "find it". Not Ctrl-F either — the composer is a `vxfw.TextField` and
      holds focus, so it consumes Ctrl-F as forward-char before the root
      Model sees it. TextField's chord list (Ctrl-A/B/D/E/F/J/K/U/W and the
      Alt- word motions) is exactly the set that cannot be bound at the app
      level, which is worth knowing before adding any keybinding here.

      Search drives the same `view_end` anchor paging does rather than
      introducing a second notion of where the transcript is looking, so the
      draw, the scrollbar and the bottom-alignment math need no knowledge of
      it. It matches on substring, not `fuzzyMatch`: a subsequence match over
      a thousand-line transcript matches nearly every line, which is useful
      for picking one of a dozen commands and useless for finding one line.
- [x] **Slash-command fuzzy palette.** Shipped: **Ctrl-P** opens a third
      `PickerKind` over `command_registry` in the same modal `/model` and
      `/theme` use, filtered by the same `fuzzyMatch` subsequence test. It
      matches mid-word (`mdl` -> `/model`), on an alias (`exit` -> `/quit`)
      and on the help text (`switch` -> `/model`), which is what separates it
      from Tab-complete: that can only extend a prefix of a name already
      remembered. Enter runs a command that takes no arguments outright and
      loads `"<name> "` into the composer for one that does, the same split
      Tab-complete makes on a unique match. Bound to a key rather than a
      spelling because a `/palette` command would have to be looked up in the
      thing it opens.
- [x] **Inline `!shell` escape.** grok/kimi/opencode (and Pi) run a shell line
      with a `!` prefix without leaving the loop. Shipped: `submit()`
      intercepts a leading `!` before `parseCommand` (`parseShellEscape`),
      `splitShellArgs` builds one fixed argv, and `host.execUnderPolicy` runs
      it past the same `ck_exec` gate a tool goes through — not a shell, so no
      pipes, globs, redirections or `$VAR`. The allowlist is the union of the
      registry's `exec_allow` plus `agent.repl_exec_allow`; bare `!` prints it.

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
- [x] **Real markdown outside fenced code.** Shipped: `mdLineSegments` parses
      each line's inline markdown into styled segments — `**bold**`,
      `*italic*`/`_italic_`, `` `code` ``, `#`..`######` headings, and
      `-`/`*`/`+` bullets (which get an accent `•`) — with the markers
      stripped and an unmatched marker left literal. Wired into both the
      completed transcript and the live stream, so prose is styled as it
      arrives rather than only once the turn lands, and it falls back to plain
      on any parse failure.

      What is still missing is narrower than this item used to claim: it is
      line-level only, so multi-line constructs (tables, block quotes, nested
      or ordered lists, setext headings) are not modelled. `clanker run`'s
      `MdStream` remains the richer renderer.
- [ ] **Multi-line input** (Shift+Enter or a heredoc paste mode). `vxfw.TextField`
      is single-line; Enter always submits.
- [ ] **Image / multimodal input.** The web UI has an attachment path (webui
      1.3); this REPL has no route for a task that needs one.
- [ ] **Plan mode toggle.** `Agent.plan_mode` exists and the web UI toggles it
      (webui 2.2); nothing here sets it, so no propose-then-apply flow.
- [ ] **Truecolor autodetection.** `/theme` shipped (registered in
      `command_registry`, a `PickerKind` in the same modal `/model` uses), so
      the RGB palettes are reachable without setting `CLANKER_THEME`. What
      remains is autodetecting truecolor support so a capable terminal gets
      colour by default instead of the bold-only 16-colour theme.

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
