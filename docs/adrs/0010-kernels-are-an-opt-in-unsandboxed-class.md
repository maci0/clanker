# ADR 0010 — Eval kernels are opt-in, and sandboxed where a sandbox exists

## Status

Accepted. Revised 2026-08-14: the Python kernel runs under a real WASM/WASI
sandbox (`src/sandbox/python_wasi.zig`, zwasm's own WASI host) when the
interpreter `scripts/setup-python-wasi.sh` fetches is present. The original
"opt-in unsandboxed" framing this ADR shipped with now describes only the
fallback path, kept for checkouts that have not run that script, and only
until it is removed (see Consequences). The `bun`/JS kernel is unimplemented
and this ADR's original posture for it — a real subprocess, no sandbox —
still stands until it lands.

## Context

ADR 0007's posture is that the plugin manifest is the security boundary and
it is enforced. A persistent eval kernel (PRD 0016) was specced as a real
`python3` or `bun` subprocess with the host's ambient filesystem permission —
the inverse of that posture once the process is running. zwasm (already
vendored for clanker's own tool sandbox) turned out to expose a public WASI
preview1 host (fd/path/proc/clocks, directory preopens, fuel and wall-clock
limits) complete enough to run an official CPython WASI build under the same
kind of confinement every other tool call already gets. DAP (PRD 0017) will
share the same session-scoped subprocess registry regardless of which kernel
backend lands first.

## Decision

Kernels are a named, opt-in tool class, sandboxed by whichever mechanism the
backend actually has:

- `kernel.enabled = false` by default. Calling the tool while off returns a
  disabled error and starts no process.
- The `kernel` manifest sets `"confirm": true`.
- **Python**: `runPythonCell` (`src/sandbox/host.zig`) prefers
  `agent.kernel.python_wasi_binary` (default
  `vendor/python-wasi/bin/python-3.12.0.wasm`, not committed —
  `scripts/setup-python-wasi.sh` fetches and sha256-verifies it). Under
  zwasm/WASI the cell runs with a fuel budget, a wall-clock timeout, a memory
  cap, and exactly one filesystem preopen (the interpreter's own stdlib) —
  no other path and no network syscalls at all exist in the WASI preview1
  import set this binary links against. When the binary is absent,
  `runPythonCell` falls back to an **unsandboxed** host `python3` subprocess
  and logs a deprecation warning naming the setup script; this fallback
  exists so an unconfigured checkout still works, not as a supported target.
- **JS (`bun`)**: still unimplemented; when it lands it inherits this ADR's
  original unsandboxed posture until (if) an equivalent WASI runtime exists
  for it.
- cgroups (or equivalent) CPU/memory quotas are still required before any
  recommended/default config flips `kernel.enabled` to true for the
  unsandboxed fallback path specifically — the WASI path's fuel/memory/
  timeout limits already bound the sandboxed path without them.

The session subprocess registry (`src/agent/subprocess.zig`) is the shared
lifecycle for whichever backend is running a real host subprocess
(unsandboxed Python fallback, or `bun` once it exists): register by
`<session-id>/<kind>`, SIGTERM the group on session end. The WASI path is
in-process (an embedded zwasm `Instance`, not a subprocess) and has nothing
to register there.

## Consequences

- A configured Python kernel is bounded by the sandbox, not by config +
  confirm alone: fuel/memory/timeout traps replace "the sandbox does not
  bound this" as the actual answer to "what stops a runaway cell."
- The unsandboxed `python3` fallback is deprecated. It has no removal date
  yet; when one is set, `agent.kernel.python_wasi_binary` being unreachable
  becomes a hard error instead of a warned fallback.
- A missing `python3` (fallback path) or `bun` is a soft runtime error, not a
  build dependency. A missing WASI interpreter is not a build dependency
  either — `scripts/setup-python-wasi.sh` is a separate, explicit step.
- Quota work is still a pre-default-on requirement for the fallback path,
  not a v1 opt-in ship blocker; it is not required for the WASI path, which
  already has its own resource limits.
