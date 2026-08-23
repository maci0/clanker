# Bug — A clipboard paste request the terminal never answers leaves the REPL composer unable to submit

## TL;DR

- **What failed:** Ctrl+Shift+V and Shift+Insert (src/tui/repl.zig) both set self.in_paste = true and fire an OSC 52 clipboard read. in_paste is cleared only by a .paste payload or a bracketed-paste .paste_end. Most terminals disable clipboard reads, so the reply never comes and in_paste stays true: Enter then takes the paste branch and inserts a newline marker instead of submitting, forever, with nothing on screen saying why. awaiting_clipboard is set at both call sites and never read.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

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

## Verification

## Follow-up

## References

- Investigation: none yet
