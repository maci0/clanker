# Bug — zigLibDir spawns bare zig with no PATH search or environment, always failing

## TL;DR

- **What failed:** zigLibDir() spawned zig with a bare argv[0] (no PATH search) and no environ_map (child gets no HOME), so zig env always failed: FileNotFound, then AppDataDirUnavailable on stderr with empty stdout. zig_std and the std_api eval were permanently broken; two consecutive improve-self runs today died on this eval regardless of their proposal.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-18. Fixed in src/sandbox/host.zig (zigLibDir resolves zig via resolveExecPath and passes environ_map) plus three call-site updates in src/improve/engine.zig; verified by clanker eval std_api going 0.00 FAIL -> 1.00 PASS and clanker gate all-green.

## Status

Resolved on 2026-08-18. Fixed in src/sandbox/host.zig (zigLibDir resolves zig via resolveExecPath and passes environ_map) plus three call-site updates in src/improve/engine.zig; verified by clanker eval std_api going 0.00 FAIL -> 1.00 PASS and clanker gate all-green.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Symptom and impact

Two independent `clanker improve-self` runs on 2026-08-19, with entirely different staged proposals (a `Graph.add` hash-map optimization; a `toolDescriptorGate` wasm-path check), both failed the exact same capability eval on the first attempt:

```
std_api: 0.00 FAIL ... tool 'zig_std' -> 59 bytes ...
```

59 bytes matches the `{"ok":false,"error":"...: not found"}` shape, not a real symbol lookup. The identical failure across unrelated proposals ruled out both proposals as the cause and pointed at the eval mechanism itself.

Reproduced directly on main with `clanker eval std_api` (no staged tree involved): same 0.00 FAIL.
## Reproduction

```
clanker eval std_api --provider deepseek
```
fails on main (pre-fix) with the same short `ok:false` payload.

Added temporary `std.log.warn` calls in `ckStdApi` and `zigLibDir` (host.zig) to see the real state:
1. First pass: `lib_dir=""` — `zigLibDir()` was returning empty.
2. Second pass, deeper in `zigLibDir`: `zig env spawn failed: FileNotFound`.
3. After resolving `argv[0]` via `resolveExecPath` (mirroring the existing `rg` call two lines below), spawn succeeded but `stdout_len=0`.
4. Manually reproduced the empty-stdout case outside clanker: `HOME= /home/maci/.local/bin/zig env` prints `error: unable to resolve zig cache directory: AppDataDirUnavailable` to stderr and exits 1, stdout empty.
## Root cause

Two independent bugs stacked in `zigLibDir()` (src/sandbox/host.zig), both from calling `std.process.run` the naive way:

1. `argv = {"zig", "env"}` — a bare argv[0]. Zig 0.16's `std.process.spawn` treats argv[0] as a literal file path and does not search PATH for it (per `spawnPath`'s doc comment: "argv[0] is *always* treated as a file path"). This is the exact constraint the file's own `ckStdApi`/`rg` call already works around three lines below via `resolveExecPath`, but `zigLibDir` was never updated to match. Result: every call failed `FileNotFound`, silently swallowed by `catch return zig_lib_dir` (empty).
2. `RunOptions.environ_map` was left at its default, `null`. Per its doc comment ("Replaces the child environment when provided"), `null` gives the child no inherited environment at all — not the parent's. `zig env` needs `HOME` to resolve its cache directory and, without it, fails with `AppDataDirUnavailable` on stderr while stdout stays empty. Neither the old nor new code checked `res.term` (exit status) or read `res.stderr`, only `res.stdout.len`, so this failure mode was invisible.

Fixing only #1 (resolveExecPath for argv[0]) got the binary found but still produced empty stdout from #2 — both had to be fixed together.
## Resolution

`src/sandbox/host.zig`:
- `zigLibDir` now takes an `environ_map: *std.process.Environ.Map` parameter.
- Resolves `zig`'s real path via the existing `resolveExecPath` helper before spawning (same pattern as the `rg` call in `ckStdApi`).
- Passes `.environ_map = environ_map` into `std.process.run`'s `RunOptions` so the child `zig env` inherits `HOME`/`PATH`/etc. and can resolve its cache directory.
- `ckStdApi` passes `h.sandbox.environ_map` through.

`src/improve/engine.zig`: the three `zigLibDir` call sites (`self.ctx.io` × 2, `ctx.io` × 1 in a test) updated to pass `self.ctx.environ_map` / `ctx.environ_map` — `client.Ctx` already carries this field for provider credential resolution, so no new plumbing was needed.
## Verification

- `clanker eval std_api --provider deepseek`: `0.00 FAIL` (59-byte error payload) before the fix, `1.00 PASS` (2690-byte real symbol match) after.
- `zig build test`: exit 0 (read directly, not through a pipe, per the AGENTS.md caveat about `tail` masking the real exit code).
- `clanker gate`: all 9 checks pass (build, tests, tools, fmt, lint, provider-kind, test-root-coverage, tools-ts-toolchain, release-contract).
- Diff is 2 files, +17/-7, no behavior outside `zigLibDir`'s three call sites touched.
## Follow-up

Neither `std.process.run` call site checked `res.term` or logged `res.stderr` on a nonzero exit with empty stdout — that pattern (silently treating a failed subprocess as "no output") is worth a sweep across other bare `std.process.run(...) catch return <empty>` call sites in this file, since this bug survived undetected until a capability eval happened to catch it.