# PRD — Eval kernel

## Status

Partial. Registry, disabled-by-default guest, magic prefixes, ADR 0010
carve-out, and `ck_kernel` (one-shot Python eval, ADR 0011) are in. The
Python path now runs under a real WASI sandbox
(`src/sandbox/python_wasi.zig`) when `scripts/setup-python-wasi.sh` has
fetched the interpreter; without it, `runPythonCell` falls back to the
original unsandboxed host `python3` subprocess and logs a deprecation
warning. Persistent supervisors, JS/Bun (still unsandboxed if it lands
before an equivalent WASI runtime exists for it), the loopback bridge, the
venv/`%pip` flow described below, and session-end SIGTERM wiring are still
open — the shipped `ck_kernel` path is a single cell in, one JSON result
out, no process state kept between calls.
Sources of truth: `src/sandbox/host.zig` (`runPythonCell`),
`src/sandbox/python_wasi.zig`, `src/agent/subprocess.zig`, `src/config.zig`
(`Kernel`), `tools/zig/kernel.zig`, `tools/zig/kernel_magic.zig`,
[ADR 0010](../adrs/0010-kernels-are-an-opt-in-unsandboxed-class.md).

## Problem

When the agent needs to run code it emits a `git` or shell command via the `exec`
or `git` tools. Each call spawns a fresh process with no state from prior calls.
There is no way to define a variable in one tool call and reference it in the
next, accumulate a dataset across cells, or run a REPL-like exploratory session
without re-executing from scratch each time.

Python and JavaScript are the dominant languages for data work, quick prototypes,
and numeric checks. Neither has a native WASM runtime available in the clanker
sandbox today. omp's eval kernel addresses this with persistent subprocess kernels
(Python) and Bun workers (JS) that maintain state across calls within a session.
The loopback bridge lets kernels call back into the host's own tools, so the
kernel can read a file or call another tool mid-execution.

## Goals

1. A new `kernel` WASM tool supporting two kernel types: `python` (subprocess,
   `python3`) and `js` (Bun worker). Both are optional; the tool reports a clear
   error if the runtime is not installed.
2. Kernels are session-scoped: one per (session-id, kernel-type) pair, started on
   first use and kept alive until the session ends or an explicit `reset` is
   requested.
3. A loopback bridge: a local HTTP server (`localhost:0`, port assigned at
   startup) that both kernel types can call to invoke any of the host's own WASM
   tools by name. The kernel gets the bridge URL via an environment variable
   (`CLANKER_BRIDGE_URL`).
4. Magic prefixes in cells: `%pip install <pkg>` installs into the kernel's
   venv, `%time` wraps execution in a timer, `%%bash` runs the cell body as a
   shell command via `ck_exec`, `!cmd` runs a single command.
5. Kernel state directories (`state/kernels/<session-id>/<type>/`) hold the
   venv and any files the kernel writes. Each kernel's cwd is that directory.
   They are cleaned up when the session ends (or manually via a `kernel` call
   with `reset: true`).
6. The tool returns structured output: stdout, stderr, a `result` field (the last
   expression value, repr'd), and a `duration_ms` field.
7. Extract a session-scoped subprocess registry (keyed by session, SIGTERM on
   session end) that PRD 0017 (DAP) reuses. This registry is a hard dependency
   for DAP and ships as part of this PRD's host work, not as a later refactor.

## Non-goals

- Not a Jupyter server. There is no `.ipynb` format, no cell IDs, no checkpoint
  files. The kernel is a stateful process; clanker manages it, not a notebook
  server.
- Python cells run under zwasm's own WASI sandbox (fuel, wall-clock timeout,
  memory cap, one filesystem preopen, no network syscalls at all) when
  `scripts/setup-python-wasi.sh` has fetched the interpreter; see
  [ADR 0010](../adrs/0010-kernels-are-an-opt-in-unsandboxed-class.md). Absent
  that, and for the still-unimplemented Bun/JS kernel, the tool class stays
  what ADR 0010 originally specced: a real host process with ambient
  filesystem permissions, gated only by `"confirm": true` on the manifest and
  `kernel.enabled = false` by default — not bounded by `fs_prefixes` once
  running.
- Not persistent across clanker restarts. Kernel state is in-memory plus the
  kernel directory; a clanker restart kills the process. The directory survives
  for inspection but re-running the session starts a fresh kernel. JS kernel
  state is ephemeral (no serialize-to-disk on each cell).
- Not a general MCP bridge. The loopback bridge exposes only the host's
  registered WASM tools, not arbitrary HTTP endpoints. It uses the same
  descriptor-gated dispatch as the normal tool call path.
- Not default-on. Resource quotas (CPU/memory via cgroups or equivalent) must be
  documented and preferably implemented before `kernel.enabled` is flipped to
  true in any recommended/default config. Quotas are a pre-default-on
  requirement, not a v1 ship blocker while the feature remains opt-in.

## Design

**ADR 0007 carve-out (decided).** ADR 0007's posture is that the manifest is the
security boundary and it is enforced. A kernel is an unsandboxed subprocess with
the host's ambient filesystem permission: the inverse of that posture once the
process is running. v1 treats kernels as a named, opt-in unsandboxed tool class,
gated by `kernel.enabled = false` (default) plus manifest `"confirm": true`.
Prefer a short ADR that records this carve-out (and points at this PRD) rather
than only a paragraph here; the PRD states the policy either way.

**Tool input schema.**

```json
{
  "kernel": "python",
  "cell": "import pandas as pd\ndf = pd.read_csv('data.csv')\ndf.head()",
  "reset": false,
  "timeout_ms": 10000
}
```

`kernel` is `"python"` (default) or `"js"`. `reset` kills the existing kernel
and starts fresh. `timeout_ms` caps cell execution; default 10000.

**Python kernel.** Started via `python3 -c` wrapping a small supervisor script
that reads cell text from stdin and writes JSON to stdout. The supervisor runs in
a venv at `state/kernels/<session-id>/python/venv/`. Working directory is
`state/kernels/<session-id>/python/`. The supervisor loop:

1. Reads a JSON line: `{"cell": "..."}`.
2. Executes in the interpreter's `__main__` namespace (persistent across calls).
3. Captures stdout/stderr via `io.StringIO` redirect.
4. Returns `{"stdout": "...", "stderr": "...", "result": "...", "ok": true}`.

The venv is created with `python3 -m venv` on first use. `%pip install <pkg>`
translates to a `pip install` in the venv (via subprocess inside the supervisor).

**JS kernel (decided: ephemeral state).** A Bun worker script at
`state/kernels/<session-id>/js/worker.ts`. The host spawns `bun run <script>`
and communicates over stdio JSON in the same protocol as the Python supervisor.
State lives in a JS module-level Map for the life of the process. No
serialize-to-disk on cell completion; a crash or restart loses in-memory state
(cwd files on disk remain). Working directory is
`state/kernels/<session-id>/js/`.

**cwd (decided).** Each kernel's process cwd is
`state/kernels/<session-id>/<type>/`, isolating file writes without changing
`fs_prefixes`.

**Loopback bridge.** The host starts an HTTP server on `localhost:0` at clanker
startup (or lazily on first `kernel` call). It listens for `POST /tool/<name>` with
a JSON body matching the named tool's input schema and returns the tool's result
as JSON. The kernel receives the port as `CLANKER_BRIDGE_URL=http://localhost:<port>`.

Bridge authentication: a random token set as `CLANKER_BRIDGE_TOKEN`. The kernel
must include it as `Authorization: Bearer <token>`. Requests without the token
return 401.

The bridge runs every call through the normal descriptor-gated dispatch
(`runtime.loadNamedTool` + `ToolModule.executeTool` in `src/sandbox/runtime.zig`),
so sandbox policies (fs_prefixes, exec_allow, network_allow) are enforced
exactly as for WASM tool calls.

**Magic prefixes.** Parsed by the WASM guest before sending to the kernel:

| Prefix | Action |
|---|---|
| `%pip install <pkg>` | Runs `pip install <pkg>` in the venv subprocess; returns install output |
| `%time` | Wraps the rest of the cell in a timer; appends `Wall time: Nms` to output |
| `%%bash` | Sends the cell body to `ck_exec` with `["bash", "-c", "<body>"]`; returns exec result |
| `!<cmd>` | Sends a single command to `ck_exec`; returns exec result |

**Output handling.** Stdout and stderr are captured per cell, not accumulated.
`result` is the repr of the last expression in the cell if it is not `None` (Python)
or not `undefined` (JS). Output is capped at `kernel.max_output_bytes` (default
65536) before returning.

**Session subprocess registry (decided: extract here).** The host tracks a
shared `SessionSubprocessRegistry` (a `std.StringHashMap` keyed by
`<session-id>/<kind>`) mapping to OS process handles. On session end (detected
by the session cleanup path in `src/agent/loop.zig`), all processes for that
session are sent SIGTERM and their directories are scheduled for deletion after
`kernel.cleanup_delay_ms` (default 5000, to allow in-flight reads). PRD 0017
(DAP) hard-depends on this registry; design and land it once here, then have DAP
register adapters under the same lifecycle.

**Quotas (pre-default-on).** Document that cgroups-based (or equivalent)
CPU/memory limits per kernel are required before recommending
`kernel.enabled = true` as a default. Opt-in use without quotas is allowed; making
the feature default-on without quotas is not.

**Dependencies.**

- Prefer a short ADR recording the ADR 0007 unsandboxed-tool carve-out (named
  opt-in class, `enabled=false` + `confirm:true`). If the ADR is delayed, this
  PRD's Design section is the interim policy of record.
- Shared `SessionSubprocessRegistry` is a hard deliverable of this PRD and a
  hard dependency for PRD 0017 (DAP).
- Loopback bridge uses existing descriptor-gated dispatch
  (`src/sandbox/runtime.zig`).
- Host needs `python3` and/or `bun` on PATH for the respective kernels; absence
  is a soft runtime error, not a build dependency.
- Session cleanup path in `src/agent/loop.zig`.

**Implementation.**

1. **Session subprocess registry**: extract/create shared registry API (register,
   SIGTERM on session end, keyed by session+kind). Land tests that DAP can
   reuse the same surface.
2. **Config + gate**: `kernel.enabled = false` default; manifest `"confirm":
   true`; clear disabled error when called while off.
3. **Python supervisor + venv**: cwd under `state/kernels/<session>/python/`;
   persistent `__main__`; `%pip` support.
4. **JS Bun worker**: ephemeral Map state; same stdio JSON protocol; cwd under
   `.../js/`.
5. **Loopback bridge**: localhost token auth; dispatch through normal tool path.
6. **Magic prefixes + output caps** in the WASM guest.
7. **ADR 0007 carve-out** (short ADR preferred) and quota docs before any
   default-on flip.
8. **Deferred / pre-default-on**: cgroups quotas; stdout streaming over
   `/api/run`; rich matplotlib/Vega output.

## Failure modes

| Condition | Behaviour |
|---|---|
| `python3` not found on PATH | Tool returns `{"ok": false, "error": "python3 not found; install Python 3.10+"}` |
| `bun` not found on PATH | Same for the JS kernel |
| Cell execution exceeds `timeout_ms` | Kernel process is killed; tool returns a timeout error; kernel is restarted fresh on next call |
| Kernel process crashes (non-zero exit) | Tool returns stderr content and `ok: false`; a fresh kernel starts on the next call |
| Loopback bridge returns an error for a tool call | The error text is returned to the kernel as an exception/rejected promise; the cell fails with the bridge error |
| `reset: true` while a cell is mid-execution | Not possible: the tool call is synchronous; `reset` only applies at the start of a new call |
| `state/kernels/` directory not writable | Tool returns a setup error; kernel does not start |
| `kernel.enabled = false` | Tool returns a disabled error; no process started |

## Acceptance criteria

- [x] `kernel.enabled = false` (default): the tool is present in the registry
      but returns a "disabled" error when called; no kernel is started.
- [x] Manifest sets `"confirm": true`; tool is documented as a named opt-in
      unsandboxed class ([ADR 0010](../adrs/0010-kernels-are-an-opt-in-unsandboxed-class.md)).
- [ ] With `kernel.enabled = true` and Python installed: `{"kernel": "python",
      "cell": "1 + 1"}` returns `{"result": "2", "ok": true}`.
- [ ] Python state persists across calls in the same session: define `x = 10` in
      one call, read `x` in the next, get `10`.
- [ ] JS state is process-ephemeral: survives cells in one process life, lost on
      crash/restart (no disk serialize of the Map).
- [ ] Kernel process cwd is `state/kernels/<session-id>/<type>/`.
- [ ] `%pip install requests` installs into the kernel's venv (not the system
      Python); verify `import requests` works in the next call.
- [ ] `reset: true` clears kernel state; a variable defined before reset is not
      visible after.
- [ ] The loopback bridge dispatches a `read_file` call from inside a Python cell
      and returns the file content.
- [ ] Bridge requests without the auth token return 401 and do not invoke the
      tool.
- [ ] `%%bash` runs via `ck_exec`; the exec policy (exec_allow) is enforced.
- [ ] Cell execution exceeding `timeout_ms` kills the kernel and returns a
      timeout error; the next call starts a fresh kernel.
- [ ] Session cleanup removes `state/kernels/<session-id>/` within
      `kernel.cleanup_delay_ms` and SIGTERMs registered subprocesses via the
      shared registry.
- [x] Session subprocess registry is usable by PRD 0017 without a second
      lifecycle implementation.
- [x] Quota requirement is documented as a blocker for default-on, not for
      opt-in v1.
- [x] Unit tests cover: magic prefix parsing, kernel registry lifecycle.
      Bridge auth token check is still open with the loopback server.

## Open questions / future work

- **Output streaming.** Long-running cells streaming partial stdout via
  `/api/run` SSE remains future work.
- **Rich output (matplotlib, Vega).** Detecting figures / Vega specs for the web
  UI remains future work.
- **Quotas before default-on.** cgroups quotas remain required before flipping
  `kernel.enabled` default; not a v1 opt-in ship blocker.
