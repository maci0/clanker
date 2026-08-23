# Bug — a run using the debug tool leaks a hash-map allocation when launch times out

## TL;DR

- **What failed:** A clanker run whose only tool call was debug/launch against a real lldb-dap exited with a DebugAllocator leak report (std hash_map putContext -> grow -> allocate). The same run shape with no tools exits clean, twice over. Not traced to a file yet; the launch had timed out and the adapter was SIGTERMed and reaped, so the Registry row teardown on the timeout path is the first place to look (src/agent/subprocess.zig, and runBounded expiry in src/debug/dap.zig).
- **Impact:** A leaked allocation at process exit, reported loudly by the DebugAllocator. No user-visible misbehaviour observed; the run itself completed and answered. Noticed while verifying the two DAP ordering fixes, not caused by them.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

The run finishes and prints its answer, then exits with

```
[ERROR] (DebugAllocator) memory address 0x... leaked:
  .../std/hash_map.zig:1477 in allocate
  .../std/hash_map.zig:1434 in grow
  .../std/hash_map.zig:1295 in growIfNeeded
  .../std/hash_map.zig:1115 in getOrPutContextAdapted
  .../std/hash_map.zig:1100 in getOrPutContext
  .../std/hash_map.zig:1026 in putContext
```

The clanker frames below `putContext` were elided by the "additional stack
frames may have been skipped" cut, so the owning map is not identified yet.

## Reproduction

Observed once, on 2026-08-23, from a worktree at 52bfc739 plus the two DAP
ordering fixes:

1. `config.local.toml` with `[debug] enabled = true` and a `lldb` adapter
   pointing at `/Library/Developer/CommandLineTools/usr/bin/lldb-dap`.
2. `clanker run '<prompt telling the model to call debug op launch, then
   disconnect>' --provider deepseek --no-worktree`.
3. The launch expires (see the note below on why lldb-dap answers nothing on
   this machine) and the tool returns the timeout error; the run then answers
   and exits with the leak above.

Control: the same binary, same flags, prompt `Reply with exactly the word:
pong. Use no tools.` — run twice, clean exit both times, no leak line.

## Root cause

Not traced. The launch had expired, so `runBounded`'s expiry path had run:
SIGTERM, optional SIGKILL after the grace, then
`sess.reg.terminate(session_id, kind)`. A `Registry` row is keyed in a hash
map, which fits the trace shape, so that teardown is the first place to look
(`src/agent/subprocess.zig`), followed by anything the debug tool puts in a map
per call.

Worth separating from the adapter question: Apple's `lldb-dap` answered
`initialize` and then nothing at all to `launch`, with or without a
`configurationDone` — but plain `lldb -b -o run` also hangs at `run` on this
machine, so debugging is blocked here at the OS level and the timeout is
expected, not a client defect.

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
