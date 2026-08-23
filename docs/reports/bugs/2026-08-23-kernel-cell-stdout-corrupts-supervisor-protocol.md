# Bug — A kernel cell writing to fd 1 corrupts the supervisor's JSON line protocol

## TL;DR

- **What failed:** A kernel cell that writes to fd 1 directly (subprocess.run without capture_output, or os.write(1,...)) has its bytes interleaved into the supervisor's JSON reply line, so the host's parseResponse fails with SyntaxError and a valid cell reports a protocol error. The supervisor prints one JSON line per request on the stdout its children inherit, and nothing separates the two. Found while writing the posture test for the unsandboxed-kernel record.
- **Impact:** A correct cell reports a protocol error. `run_cell` redirects `sys.stdout` at the Python level, so pure-Python `print` is safe; anything writing to the file descriptor underneath it is not, which is every subprocess the cell starts without `capture_output`.
- **Resolution:** Resolved on 2026-08-23. Candidate fix (1): the supervisor dups fd 1 to a private non-inheritable descriptor (PEP 446) for its replies and repoints fd 1 and fd 2 at capture files for the process's life, draining them into the cell's stdout/stderr. No spawn-contract change. Pinned by 'descriptor-level cell output is captured, not spliced into the reply' in src/sandbox/kernel.zig; with the protocol put back on fd 1 that test fails with the reported error.SyntaxError out of parseResponse.

## Status

Resolved on 2026-08-23. Candidate fix (1): the supervisor dups fd 1 to a private non-inheritable descriptor (PEP 446) for its replies and repoints fd 1 and fd 2 at capture files for the process's life, draining them into the cell's stdout/stderr. No spawn-contract change. Pinned by 'descriptor-level cell output is captured, not spliced into the reply' in src/sandbox/kernel.zig; with the protocol put back on fd 1 that test fails with the reported error.SyntaxError out of parseResponse.

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

Fixed by candidate (1) below, in `supervisor_src` (`src/sandbox/kernel.zig`).
Found while writing the posture test for
[the unsandboxed-kernel record](2026-08-23-kernel-persist-path-is-unsandboxed.md)
and filed rather than folded into it, because it is a protocol bug and not a
confinement one. That is still true: the kernel is no easier to confine now,
only no longer corrupted by its own output.

The two candidates that were open were:

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

(1) landed, in the shape that needs no change to the spawn contract: rather
than asking the host for a fourth descriptor, the supervisor calls `os.dup(1)`
at startup, keeps that copy for its replies, and `os.dup2` a capture file over
fd 1 (and fd 2) for the life of the process. The host still reads the same
pipe, so `ensureSupervisor` and `parseResponse` are unchanged. `os.dup`
returns a non-inheritable descriptor (PEP 446), so no child of a cell holds
the protocol fd, and a cell that reopens `/dev/stdout` reaches the capture --
which is the property (2) does not have.

Repointing once at startup rather than around each cell also removes the
exception-path worry (2) carried: there is no restore to get wrong.

Each reply drains the two capture files and appends fd-1 bytes to `stdout` and
fd-2 bytes to `stderr`, after the Python-level `StringIO` capture. The order
between the two streams is not recoverable, so it is documented rather than
claimed. The drain is capped at 1 MiB per stream with a `[N more byte(s)
dropped]` note, so a runaway cell cannot make the supervisor read its whole
output into memory.

fd 2 was folded in with fd 1 because the supervisor spawns with
`.stderr = .ignore`: a child's diagnostics went to `/dev/null`, so a failing
uncaptured command explained nothing. It was not corrupting anything, so it is
an improvement rather than part of the defect.

The posture test's `capture_output=True` still holds and is kept, now so that
assertion stays about exec reach only; the uncaptured form has its own test.

## Verification

`test "descriptor-level cell output is captured, not spliced into the reply"`
in `src/sandbox/kernel.zig` runs three cells through the shipped `eval` and
asserts on the returned *content*, not only on `ok`: discarding the bytes would
also stop the parse error and would lose the output instead.

- `os.write(1, b"STRAY-FD1\n")` then `1 + 1` -> `ok`, `result` `"2"`, and
  `STRAY-FD1` in `stdout`.
- `subprocess.run(["echo","UNCAPTURED-CHILD"])` with no `capture_output` ->
  `UNCAPTURED-CHILD` in `stdout`.
- `os.write(2, b"STRAY-FD2\n")` -> `STRAY-FD2` in `stderr`.
- `print("py-level")` still lands in `stdout` and carries no leftover `STRAY`
  from the earlier cells, so the drain does not bleed between replies.

That the test fails for the reported reason, not merely that it passes now:
putting the protocol back on fd 1 (`_proto = os.fdopen(1, ...)`) and moving the
capture off it fails the same test with

```
error: ... failed:
                           else => return error.SyntaxError,
```

which is the stack at the top of this record.

Not verified with a live model. `ck_kernel` refuses unless `kernel.enabled` is
true, which is off by default and is a posture change to the machine rather
than to the run, so the reproduction is the deterministic test above.

## Follow-up

- fd 2 is captured the same way now, so a child's diagnostics reach the caller
  instead of `/dev/null`. The spawn still passes `.stderr = .ignore`, which is
  now only about the supervisor's own interpreter-level errors (a crash before
  the capture is installed). Those are still lost.
- A cell can still corrupt the protocol by writing to the descriptor `os.dup`
  happened to hand out (fd 3 in practice). That is not defended and is not
  worth defending on this path: the cell already has arbitrary code execution
  in the supervisor's own process, which is the separate
  [confinement defect](2026-08-23-kernel-persist-path-is-unsandboxed.md).

## References

- Investigation: none. The stack trace named the parse site and the supervisor
  source made the cause plain.
- Related: [production kernel cells run unsandboxed](2026-08-23-kernel-persist-path-is-unsandboxed.md) — found while writing that record's test.
- `src/sandbox/kernel.zig` — `supervisor_src` (the writer) and `parseResponse` (the reader).
- [PRD 0016](../../prds/0016-eval-kernel.md) — the kernel spec.
