# Bug — A kernel cell writing to fd 1 corrupts the supervisor's JSON line protocol

## TL;DR

- **What failed:** A kernel cell that writes to fd 1 directly (subprocess.run without capture_output, or os.write(1,...)) has its bytes interleaved into the supervisor's JSON reply line, so the host's parseResponse fails with SyntaxError and a valid cell reports a protocol error. The supervisor prints one JSON line per request on the stdout its children inherit, and nothing separates the two. Found while writing the posture test for the unsandboxed-kernel record.
- **Impact:** A correct cell reports a protocol error. `run_cell` redirects `sys.stdout` at the Python level, so pure-Python `print` is safe; anything writing to the file descriptor underneath it is not, which is every subprocess the cell starts without `capture_output`.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

A cell whose work reaches file descriptor 1 directly fails, and fails in a way
that points at the wrong thing: the host returns a JSON `SyntaxError` from
`parseResponse`, so a correct cell looks like a broken kernel.

Observed as a real test failure, not reasoned about:

```
error: ... failed:
  std/json/Scanner.zig:1104:29: in peekNextTokenType
                      else => return error.SyntaxError,
  src/sandbox/kernel.zig:128:20: in parseResponse
  src/sandbox/kernel.zig:371:20: in roundTrip
  src/sandbox/kernel.zig:271:40: in eval
```

`run_cell` swaps `sys.stdout` for a `StringIO` around the exec, so a plain
`print()` is captured correctly. That redirect is Python-level only: it rebinds
the name, it does not touch fd 1. Anything writing to the descriptor underneath
goes straight into the stream the host is parsing.

## Reproduction

```
{"cell": "import subprocess; subprocess.run([echo,hi])"}
```

The supervisor writes `hi\n` (from the child) and then its own
`{"ok": true, ...}` line to the same fd. The host reads the first line, tries to
parse `hi`, and fails.

`capture_output=True` avoids it, which is why the posture test in
`src/sandbox/kernel.zig` uses it and says why. `os.write(1, b"hi")` from a plain
cell is the same bug without any subprocess involved.

## Root cause

`supervisor_src` in `src/sandbox/kernel.zig` uses one stream for two purposes:
the request/response protocol and whatever the cell's children inherit. The
`print(json.dumps(...), flush=True)` at the end of the loop and the child's
output are both fd 1, and the host's reader assumes one JSON object per line
with nothing else in between.

## Resolution

Open. Not fixed here; found while writing the posture test for
[the unsandboxed-kernel record](2026-08-23-kernel-persist-path-is-unsandboxed.md)
and filed rather than folded into it, because it is a protocol bug and not a
confinement one.

Two candidate fixes:

1. **Move the protocol off fd 1.** Have the supervisor write replies to a
   dedicated descriptor (fd 3, or a pipe passed at spawn) and leave fd 1 to the
   cell. The host reads the protocol descriptor and can surface stray fd-1 bytes
   as cell output instead of discarding them. Correct, and it changes the spawn
   contract.
2. **Dup fd 1 away for the duration of a cell.** In `run_cell`, `os.dup2` the
   real fd 1 to a temp file (or a pipe) around the exec and restore it after,
   so descriptor-level writes are captured too and appended to `stdout`. Smaller
   and stays inside `supervisor_src`; needs care on the exception path so the
   descriptor is always restored.

(2) is the smaller change and also fixes `os.write(1, ...)`. (1) is the one that
cannot be defeated by a cell that reopens the descriptor.

Whichever lands, the assertion in the posture test that relies on
`capture_output=True` should keep working, and a new test should cover the
uncaptured form.

## Verification

Nothing to verify: not fixed. The symptom itself is verified by having hit it
as a test failure with the stack above, rather than by reading the supervisor
source and inferring it. The `capture_output=True` workaround is verified by the
posture test passing with it.

## Follow-up

- The same reasoning applies to stderr if the supervisor ever moves diagnostics
  there; it currently spawns with `.stderr = .ignore`.

## References

- Investigation: none. The stack trace named the parse site and the supervisor
  source made the cause plain.
- Related: [production kernel cells run unsandboxed](2026-08-23-kernel-persist-path-is-unsandboxed.md) — found while writing that record's test.
- `src/sandbox/kernel.zig` — `supervisor_src` (the writer) and `parseResponse` (the reader).
- [PRD 0016](../../prds/0016-eval-kernel.md) — the kernel spec.
