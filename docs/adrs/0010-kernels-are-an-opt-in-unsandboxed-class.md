# ADR 0010 — Eval kernels are opt-in, and sandboxed where a sandbox exists

## Status

Accepted, and **not implemented as written**. Corrected 2026-08-23.

The 2026-08-14 revision below declared the WASI path primary. That was never
true of the code. `ck_kernel` reaches the persistent supervisor in
`src/sandbox/kernel.zig`, a plain host `python3` subprocess with the harness's
full ambient permissions, and it always has. `runPythonCell` and
`runPythonCellSandboxed` in `src/sandbox/host.zig` — the WASI-confined functions
this ADR describes — **have no production caller** and are reachable only from
their own test, which is why the divergence went unnoticed: a green test on a
path production never takes.

The two cannot simply be joined. `python_wasi.run` executes a one-shot cell, and
the whole point of the kernel is that `__main__` survives between cells (a
checked PRD 0016 criterion), so the persist path could not have adopted the
sandboxed function as it stands.

So the original "opt-in unsandboxed" framing is what actually ships, for the
Python kernel as well as for JS. Treat every "sandboxed" statement below as
describing intended, unbuilt behaviour. Tracked as an open defect in
[docs/reports/bugs/2026-08-23-kernel-persist-path-is-unsandboxed.md](../reports/bugs/2026-08-23-kernel-persist-path-is-unsandboxed.md),
which lists the candidate fixes. This ADR needs a decision — supersede the
WASI-primary framing, or commit to a resident confined interpreter — and the
correction here is not that decision.

Historical text of the 2026-08-14 revision, kept for the record: the Python
kernel runs under a real WASM/WASI sandbox (`src/sandbox/python_wasi.zig`,
zwasm's own WASI host) when the interpreter `scripts/setup-python-wasi.sh`
fetches is present. The original "opt-in unsandboxed" framing this ADR shipped
with now describes only the fallback path, kept for checkouts that have not run
that script, and only until it is removed (see Consequences). The `bun`/JS
kernel is unimplemented and this ADR's original posture for it — a real
subprocess, no sandbox — still stands until it lands.

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
- **Python**: *(test-only: nothing in production calls `runPythonCell`. What
  runs is the unsandboxed supervisor in `src/sandbox/kernel.zig`.)*
  `runPythonCell` (`src/sandbox/host.zig`) prefers
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

- **Not achieved.** A configured Python kernel is bounded by config + confirm
  alone. Nothing stops a runaway cell: the supervisor has no fuel, memory or
  timeout trap beyond the per-call `timeout_ms` that kills and restarts it, and
  it has the harness's whole filesystem and network. The intended consequence
  was: a configured Python kernel is bounded by the sandbox, not by config +
  confirm alone, with fuel/memory/timeout traps replacing "the sandbox does not
  bound this" as the actual answer to "what stops a runaway cell."
- The unsandboxed `python3` path is deprecated on paper and is nonetheless the
  only path. Since 2026-08-23 starting a supervisor logs a warning saying so and
  every kernel reply carries `"sandboxed": false` with a reason, so an operator
  is no longer told one thing by the docs and nothing by the runtime. That is a
  correction to the reporting, not confinement: the kernel is not safer than it
  was, only accurately described.
- A missing `python3` (fallback path) or `bun` is a soft runtime error, not a
  build dependency. A missing WASI interpreter is not a build dependency
  either — `scripts/setup-python-wasi.sh` is a separate, explicit step.
- Quota work is still a pre-default-on requirement for the fallback path,
  not a v1 opt-in ship blocker; it is not required for the WASI path, which
  already has its own resource limits.
## Amendment 2026-08-23 — a kernel cell's environment is the guest's, not the harness's

This ADR says nothing about what a kernel cell may read out of its
environment, and the code said nothing either: `eval` spawned the supervisor
with no `environ_map`, which `std.process.spawn` reads as "whatever the `Io`
implementation carries". A cell therefore got two platform-injected variables
and no `HOME` or `PATH`, and on an `Io` whose captured environment is populated
it would have got every key the harness holds -- including the API keys
`ck_env` denies the guest that started the cell.

Decided, and now enforced: **a kernel supervisor is spawned with
`host.execEnvironment`, the same `envAllowed` filter `ck_exec` and `ck_job`
use.** With no `env_allow` on the `kernel` manifest that is the default set
(`PWD`, `HOME`, `PATH`, `LANG`, `LC_ALL`, `TERM`, `TZ`, `USER`) and never a
credential; naming variables in `env_allow` replaces that set rather than
adding to it.

`EvalOpts.environ_map` is required and non-optional so the question cannot be
left unanswered again: an empty map is a legitimate answer, silence is not.

Consequence, stated rather than discovered: a cell has no `TMPDIR`, since that
name is not in the default set. `argv[0]` resolution is unaffected -- 
`std.process.spawn` resolves it from the parent environment either way, so this
cannot stop `python3` being found.

This narrows the credential surface and changes nothing about confinement: the
cell still runs in an unsandboxed host `python3` process, which is the open
defect this ADR's Status section already points at. Record:
[the supervisor's environment was unspecified](../reports/bugs/2026-08-23-kernel-supervisor-environment-is-unspecified.md).