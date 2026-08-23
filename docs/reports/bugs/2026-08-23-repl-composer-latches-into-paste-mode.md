# Bug — A clipboard paste request the terminal never answers leaves the REPL composer unable to submit

## TL;DR

- **What failed:** Ctrl+Shift+V and Shift+Insert (src/tui/repl.zig) both set self.in_paste = true and fire an OSC 52 clipboard read. in_paste is cleared only by a .paste payload or a bracketed-paste .paste_end. Most terminals disable clipboard reads, so the reply never comes and in_paste stays true: Enter then takes the paste branch and inserts a newline marker instead of submitting, forever, with nothing on screen saying why. awaiting_clipboard is set at both call sites and never read.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-24. Shift+Insert no longer sets `in_paste` (which only the terminal's own bracketed-paste pair sets and clears now) but opens a bounded 1500 ms window, `paste_window_until_ms`. `composerEnterAction` (src/tui/repl.zig) decides Enter's meaning from the two together, so an OSC 52 read the terminal never answers can no longer stop the composer submitting, and `closePasteWindow` says once why Enter went back to normal. `awaiting_clipboard` is now read rather than only written. Pinned by the unit test "composerEnterAction submits once an unanswered paste window expires"; clanker gate green on all eleven checks; live pty run submits a turn after Shift+Insert where the pre-fix binary sat there inserting newline markers.

## Status

Resolved on 2026-08-24. Shift+Insert no longer sets `in_paste` (which only the terminal's own bracketed-paste pair sets and clears now) but opens a bounded 1500 ms window, `paste_window_until_ms`. `composerEnterAction` (src/tui/repl.zig) decides Enter's meaning from the two together, so an OSC 52 read the terminal never answers can no longer stop the composer submitting, and `closePasteWindow` says once why Enter went back to normal. `awaiting_clipboard` is now read rather than only written. Pinned by the unit test "composerEnterAction submits once an unanswered paste window expires"; clanker gate green on all eleven checks; live pty run submits a turn after Shift+Insert where the pre-fix binary sat there inserting newline markers.

## Symptom and impact

## Reproduction

## Root cause

`src/tui/repl.zig`:

```zig
if (key.matches(vaxis.Key.insert, .{ .shift = true })) {
    self.in_paste = true;
    requestSystemClipboard(ctx.io);
    self.awaiting_clipboard = true;
    return ctx.consumeEvent();
}
```

and the Enter handler:

```zig
if (key.matches(vaxis.Key.enter, .{})) {
    if (self.in_paste) {
        try self.text_field.insertSliceAtCursor(newline_marker);
        ctx.redraw = true;
        return;
    }
    try self.submit(ctx);
```

`in_paste` has exactly three writers of `false`: the `.paste` payload, the
bracketed-paste `.paste_end`, and nothing else. An OSC 52 *read* is refused or
unsupported by most terminals, so neither fires and the flag is latched. The
user can still type; they can no longer submit anything, `/quit` included,
and Ctrl-C while idle is the only way out.

PRD 0040's failure-mode contract for the paste path is "no action / fallback
to submit; no crash".

`awaiting_clipboard` (declared beside `in_paste`) is assigned at both request
sites and read nowhere, which is consistent with the timeout that was meant
to bound this having been lost rather than never intended.

Suggested pin: lift the decision out of the event handler into something
callable - `fn pasteModeAfter(...)` or a small `composerEnterAction(...)` -
and assert that Shift+Insert followed by Enter with no `.paste` event
submits.

## Resolution

Three changes, all in `src/tui/repl.zig`:

- Shift+Insert stops setting `in_paste`. That flag now means only "between a
  `.paste_start` and its `.paste_end`", a pair the terminal owes an end for.
- Shift+Insert instead calls `openPasteWindow`, which sets
  `paste_window_until_ms` to 1500 ms out on a monotonic clock. A terminal
  that honours the request bursts the whole payload at once, so the fold only
  has to cover one read of the tty; a terminal that refuses costs the user
  that much and no more. Monotonic and not wall time: an ntp step must not be
  able to reopen the latch this bounds.
- Enter's meaning moved out of the handler into
  `composerEnterAction(bracketed, deadline, now)`, so it is decidable without
  a terminal. `.newline` inside a bracketed paste or inside a live window,
  `.submit` otherwise.

`closePasteWindow` runs on the submitting Enter. If `awaiting_clipboard` is
still set — neither the `.paste` payload nor a bracketed pair ever arrived —
it prints one dim notice saying the terminal did not answer, which is the
"nothing on screen saying why" half of the report. Both the `.paste` and
`.paste_end` arms clear the window themselves, so an answered request is
silent.

1500 ms is a trade: a terminal that replays a clipboard as raw keystrokes
*and* takes longer than that to deliver them would submit mid-paste. No
terminal seen here does the first (they use bracketed paste, which is
unbounded and exact); the alternative on the table was the status quo, where
the composer wedges permanently.

## Verification

Unit test `composerEnterAction submits once an unanswered paste window
expires` (`src/tui/repl.zig`) covers both bracketed arms, a live window, the
expired window (the regression), and an idle composer.

`clanker gate` green on all eleven checks, on 52bfc739 + this change.

Live, over a real pty (100x30, TIOCSWINSZ) with
`--provider deepseek --model deepseek-v4-flash`: send Shift+Insert
(`\x1b[2;2~`, unanswered — nothing on the other end reads OSC 52), wait 3 s,
type `say hi`, press Enter.

- pre-fix binary built from an untouched 52bfc739 worktree: the composer grows
  a second, empty row (the ⏎ marker Enter inserted) and no turn ever runs.
- post-fix binary: the notice line
  `notice: the terminal did not answer the clipboard read (most refuse it);
  paste with the terminal's own shortcut instead` appears, the turn runs, and
  the model answers.

## Follow-up

Not a bug, but worth writing down for the next person driving the REPL over a
pty: `/quit` and idle Ctrl-C both look like they hang. They do not. `ctx.quit`
is honoured, `App.run` returns, and vaxis's `Loop.stop` then writes a device
status report "to trigger a read" so the reader thread's blocking `read` can
return. A harness that does not answer that DSR leaves the thread parked in
`thread.await` and the process alive with a frozen last frame. Any real
terminal answers it; `tests/e2e/pty.zig` answers the startup queries for the
same reason. Verified by sending one more keystroke after Ctrl-C, which
unblocks the read and lets the process exit immediately. That is why the live
check above submits a task rather than `/quit`.

## References

- Investigation: none yet
