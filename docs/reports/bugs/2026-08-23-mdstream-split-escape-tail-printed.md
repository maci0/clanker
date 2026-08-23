# Bug — An escape sequence split across two deltas has its introducer dropped and its tail printed as prose

## TL;DR

- **What failed:** MdStream.feed holds a trailing 0xC2 so a C1 control split across deltas still resolves, and holds split markdown markers, but gives an escape sequence no such treatment: a trailing lone ESC fails the i + 1 < total guard and is consumed, and a CSI or OSC running to the end of the window sets i = j with nothing held. feed("a\x1b[3") then feed("1mB") renders a1mB. The comment claims a sequence truncated at the end of the window is dropped too, but only the machinery is dropped.
- **Impact:** Escape-sequence text in model output shows visible junk like `31m` mid-sentence when it lands on a delta boundary.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

An LLM quoting ANSI codes, or tool output echoed into prose, renders the sequence's payload as text — `31m`, `1m`, `0;title` — instead of the sequence being dropped whole.

## Reproduction

`feed(&w, "a\x1b[3")` then `feed(&w, "1mB")` renders `a1mB`.

## Root cause

`MdStream.feed`'s hold buffer resolves split markdown markers and even a split C1 control (it holds a trailing `0xC2`), but not escapes: a trailing lone `ESC` fails the `i + 1 < total` guard and is consumed by `i += 1`, and a CSI/OSC that runs to the end of the window sets `i = j` with nothing held. The next `feed` starts at the payload.

## Resolution

Open. Found by a read of the code against its own doc comments and the PRD it implements, not from a live incident.

## Verification

None yet: nothing is fixed. A fix needs a unit test at the named seam plus a live REPL turn.

## Follow-up

The fix is the one already used for `0xC2`: hold the introducer and let the next chunk resolve it, which needs a slightly larger hold or an in-escape state bit. No ESC reaches the tty either way, so this is a correctness gap, not a sanitisation hole.

## References

- Investigation: none yet
