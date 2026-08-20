# Bug — lsp capability eval fails on large files, blocking every improve-self promotion

## TL;DR

- **What failed:** The lsp tool's `execStdin` (tools/zig/lib.zig) built its `{cmd,args,stdin}` JSON in a fixed 256 KiB buffer; a 248 KiB file escaped past that, so `execStdin` errored and the tool returned the generic `zls did not answer`. The lsp capability eval scored 0.00 FAIL, rejecting every staged improve-self tree. Fixed by sizing the buffer to `input.len*2+4096`.
- **Impact:** Every improve-self promotion was blocked; the batch stopped after iterations 1 and 2.
- **Resolution:** Resolved on 2026-08-20. Sized `execStdin`'s request buffer to `input.len*2+4096` instead of a fixed 256 KiB; the freshly built lsp tool returns `ok:true` on the 248 KiB loop.zig, so the lsp capability eval passes.

## Status

Resolved on 2026-08-20. Sized `execStdin`'s request buffer to `input.len*2+4096`; the freshly built lsp tool returns `ok:true` on the 248 KiB loop.zig.

## Symptom and impact

`clanker improve-self` batch stopped after iterations 1 and 2, both "all attempts
failed". The staging log repeated:

- `capability evals: 1 case(s) failed; retrying only those`
- `staged tree failed its own capability evals:`
- `lsp: 0.00 FAIL`
- `tool 'lsp' -> 41 bytes in 1026ms`

Because the lsp capability eval (evals/lsp.task.json) always scored 0.00, no
staged improve-self tree could be promoted, so no improvement could land.

## Reproduction

Call the lsp tool on a file over ~128 KiB:

- `{"action":"definition","file":"src/agent/loop.zig","line":100,"character":4}`
  (loop.zig is 247,815 bytes) returns `{"ok":false,"error":"zls did not answer"}`.
- The same call on a small file (src/main.zig, tools/zig/lsp.zig) returns
  `{"ok":true,...}` — zls itself is installed and working.

The eval is deliberately not position-sensitive (it only checks the tool
answered at all), so the failure is the tool's generic exec error, not zls.

## Root cause

`tools/zig/lib.zig` `execStdin` builds its `{cmd,args,stdin}` request in a
**fixed 256 KiB** buffer:

```zig
const wbuf = std.heap.wasm_allocator.alloc(u8, 256 * 1024) catch return error.OutOfMemory;
```

The lsp tool sends the whole source file as `stdin` (the didOpen session), and
JSON string escaping inflates source (quotes become `\"`, backslashes `\\`,
newlines `\n`). A 248 KiB file's escaped session exceeds 256 KiB before zls is
ever spawned, so `s.write(input)` fails and `execStdin` returns an ExecError the
lsp tool maps to the catch-all `else => "zls did not answer"`. The other caps
(the 1 MiB host arena, zls's own output) are large enough; this buffer is the
only one that does not scale with the file.

## Resolution

Size `execStdin`'s request buffer to the input instead of a fixed 256 KiB:

```zig
// stdin is JSON-escaped into this buffer, so it must be sized for the
// escaped length, not the raw bytes. ...
const wcap = input.len * 2 + 4096;
const wbuf = std.heap.wasm_allocator.alloc(u8, wcap) catch return error.OutOfMemory;
```

`input.len * 2 + 4096` covers the worst realistic double-escaping: the file is
escaped once when the LSP session is built, then again by `execStdin`, so a
pathological all-quote input maps 1 raw byte to `\\\"` (4 bytes), exactly 2x the
session length, with 4096 bytes of headroom for cmd/args and JSON framing.
`execStdin` is only called by the lsp tool, so sizing it to the input has no
other callers to break.

## Verification

- `zig build`, `zig build tools`, `zig build test`, `zig fmt --check` all pass
  in a worktree carrying the change.
- The freshly built `zig-out/tools/lsp.wasm`, called on src/agent/loop.zig
  (248 KiB), returns `{"ok":true,"action":"definition","locations":[]}` instead
  of the previous `zls did not answer`. The lsp capability eval's criterion
  (`includes: ["true"]`) therefore passes.

## Follow-up

The improve loop's recent failed proposals (adding diagnostics/hover/hint
actions to the lsp tool) were all rejected because the baseline lsp eval failed.
That blocker is now removed, so the loop can promote once it produces a
buildable patch.

## References

- Investigation: none yet
