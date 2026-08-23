# Bug — A tool card preview passes a raw escape sequence through behind a UTF-8 lead byte

## TL;DR

- **What failed:** cardPreview trusts the byte count a lead byte claims and copies that many bytes verbatim, advancing past them, so the copied bytes never see the OSC, CSI, stripped-control or C1 checks above. Input 0xE2 ESC '[' '3' '1' 'm' copies E2 1B 5B whole and then prints 31m as prose: a complete SGR sequence out of a tool name or arguments the model chose, reaching the terminal through the very function that exists to stop it (CWE-150).
- **Impact:** A hostile or prompt-injected tool name can drive the user's terminal through a tool card line.
- **Resolution:** Resolved on 2026-08-23. cardPreview verifies a lead byte's claimed length with utf8ValidateSlice before copying, so anything that is not the codepoint it claims advances one byte and is re-examined by the control checks.

## Status

Resolved on 2026-08-23. cardPreview verifies a lead byte's claimed length with utf8ValidateSlice before copying, so anything that is not the codepoint it claims advances one byte and is re-examined by the control checks.

## Symptom and impact

A tool card built from model-chosen text can emit a raw escape sequence to the
terminal: colour changes, cursor moves, or anything else CSI reaches. This is
the exact class `src/tui/sanitize.zig` exists to prevent (CWE-150), and
`cardPreview`'s own doc comment claims it enforces the same rule.

## Reproduction

```zig
const out = try cardPreview(gpa, "\xE2\x1b[31mred");
```

Before the fix `out` is `E2 1B 5B 33 31 6D 72 65 64` — the SGR sequence
intact. The card line is stored in the transcript and drawn through
`writeWrappedCard` → `nextCell` → `surface.writeCell`, and `nextCell` treats
`{0xE2, 0x1B, 0x5B}` as one grapheme, so vaxis writes the ESC to the tty.

## Root cause

`cardPreview` read the byte count a lead byte *claims*
(`utf8ByteSequenceLength`), copied that many bytes verbatim and advanced past
them, so the copied bytes never reached the OSC, CSI, `strippedControl` or C1
checks above. `writeSanitized` never does length-based skipping, so the two
paths genuinely diverged on the same input. The inputs are untrusted by
design: `toolCardHeader` and `toolCardArgs` are built from the tool name and
arguments the model produced.

## Resolution

The claimed length is verified with `utf8ValidateSlice` before the copy.
Anything that is not the codepoint it claims to be advances one byte and gets
re-examined by the control checks, which is what the function's "an invalid
lead byte passes through alone, same as writeSanitized" comment already
promised.

## Verification

Unit test "cardPreview refuses an escape smuggled behind a UTF-8 lead byte":
no `0x1B` survives, a truncated codepoint still passes through as bytes, and a
valid multi-byte codepoint is still copied whole. `clanker gate` green (all
eleven checks).

## Follow-up

`MdStream.feed` has a related but separate gap: an escape sequence split
across two deltas has its introducer dropped and its tail printed as prose.
Filed separately.

## References

- Investigation: none yet
