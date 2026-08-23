# Bug — Alt+Enter, the documented multi-line fallback, was bound nowhere and did nothing

## TL;DR

- **What failed:** PRD 0040 goal 1, ADR 0022 and PRD 0005 all promise Shift+Enter and an Alt+Enter fallback, and mark it shipped. Only enter+shift and keypad Enter were bound. vaxis Key.matches compares modifiers exactly, so enter+alt matched neither the shift branch nor the bare-Enter submit, and TextField drops it too. Where the terminal cannot report Shift+Enter it arrives as a plain Enter and submits, so Alt+Enter was the last chord left and it was a silent no-op.
- **Impact:** On Terminal.app, xterm, gnome-terminal and tmux's defaults, the composer had no working line-break chord at all.
- **Resolution:** Resolved on 2026-08-23. isComposerNewlineChord collects all five line-break spellings including enter+alt and kp_enter+alt, the key handler calls it, and keys_help names Alt-Enter and when to use it.

## Status

Resolved on 2026-08-23. isComposerNewlineChord collects all five line-break spellings including enter+alt and kp_enter+alt, the key handler calls it, and keys_help names Alt-Enter and when to use it.

## Symptom and impact

Pressing Alt+Enter in the REPL composer does nothing: no line break, no
submit, no notice. On a terminal that cannot report Shift+Enter — which is
every terminal not speaking the kitty keyboard protocol — that leaves no way
to compose a second line except a bracketed paste, while `/help` advertises
Shift-Enter as though it worked.

## Reproduction

In Terminal.app, run `clanker repl`, type a word and press Alt+Enter (Option
may need "use Option as Meta"). Nothing happens. Press Shift+Enter and the
line submits.

## Root cause

The composer's newline branch matched `enter+shift`, `kp_enter` and
`kp_enter+shift` only. `vaxis.Key.matches` compares modifiers for exact
equality (`matchExact` clears caps/num lock and then `std.meta.eql`s the
rest), so `enter+alt` matched neither that branch nor the bare-`enter` submit
below it. It then fell through to `vxfw.TextField`, whose own Enter binding is
exact too and whose text insertion needs `key.text`, which a control byte does
not carry. The keystroke was dropped — against the PRD's own "no action /
fallback to submit" failure-mode row, which at least promised a submit.

## Resolution

`isComposerNewlineChord` collects every line-break spelling — `enter+shift`,
`enter+alt`, `kp_enter`, `kp_enter+shift`, `kp_enter+alt` — as one pure,
testable predicate, and the key handler calls it. Alt+Enter reaches vaxis
either as legacy `ESC 0x0D` (reported as the codepoint with `alt` set) or as
kitty's `CSI 13;3u`; both match. `keys_help` now names Alt-Enter and says when
to reach for it.

## Verification

Unit test "the composer takes Alt+Enter for a line break, the documented
fallback" covers all five accepted spellings and pins that bare Enter and
Ctrl+Enter are not among them. `clanker gate` green (all eleven checks), plus
a live REPL session where Alt+Enter composed a two-line task and Enter sent
it.

## Follow-up

Shift+Alt+Enter is deliberately not bound. PRD 0040's open question about key
mapping across terminals is now answered for the fallback.

## References

- Investigation: none yet
