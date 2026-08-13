# PRD — Eval kernel

## Status

Draft. No source files yet. New WASM tool at `tools/zig/eval.zig` with manifest
`tools/manifests/eval.tool.json`. Loopback bridge starts as a local HTTP server
in the host (`src/eval/bridge.zig`). Kernel processes live in
`state/kernels/<session-id>/`.

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

1. A new `eval` WASM tool supporting two kernel types: `python` (subprocess,
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
5. Kernel state directories (`state/kernels/<session-id>/`) hold the venv and
   any files the kernel writes. They are cleaned up when the session ends (or
   manually via `eval reset`).
6. The tool returns structured output: stdout, stderr, a `result` field (the last
   expression value, repr'd), and a `duration_ms` field.

## Non-goals

- Not a Jupyter server. There is no `.ipynb` format, no cell IDs, no checkpoint
  files. The kernel is a stateful process; clanker manages it, not a notebook
  server.
- Not sandboxed by the WASM runtime. The eval kernel runs a real Python or Bun
  process with the ambient filesystem permissions. The `eval` tool manifest marks
  it `"dangerous": true` and it is disabled by default (`eval.enabled = false` in
  config).
- Not persistent across clanker restarts. Kernel state is in-memory plus the
  kernel directory; a clanker restart kills the process. The directory survives
  for inspection but re-running the session starts a fresh kernel.
- Not a general MCP bridge. The loopback bridge exposes only the host's
  registered WASM tools, not arbitrary HTTP endpoints. It uses the same
  descriptor-gated dispatch as the normal tool call path.

## Design

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
a venv at `state/kernels/<session-id>/python/venv/`. The supervisor loop:

1. Reads a JSON line: `{"cell": "..."}`.
2. Executes in the interpreter's `__main__` namespace (persistent across calls).
3. Captures stdout/stderr via `io.StringIO` redirect.
4. Returns `{"stdout": "...", "stderr": "...", "result": "...", "ok": true}`.

The venv is created with `python3 -m venv` on first use. `%pip install <pkg>`
translates to a `pip install` in the venv (via subprocess inside the supervisor).

**JS kernel.** A Bun worker script at `state/kernels/<session-id>/js/worker.ts`.
The host spawns `bun run <script>` and communicates over stdio JSON in the same
protocol as the Python supervisor. State is maintained in a JS module-level Map
that persists across cells.

**Loopback bridge.** The host starts an HTTP server on `localhost:0` at clanker
startup (or lazily on first `eval` call). It listens for `POST /tool/<name>` with
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
or not `undefined` (JS). Output is capped at `eval.max_output_bytes` (default
65536) before returning.

**Kernel lifecycle.** The host tracks a `KernelRegistry` (a `std.StringHashMap`
keyed by `<session-id>/<kernel-type>`) mapping to OS process handles. On session
end (detected by the session cleanup path in `src/agent/loop.zig`), all kernels
for that session are sent SIGTERM and their directories are scheduled for
deletion after `eval.cleanup_delay_ms` (default 5000, to allow in-flight reads).

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

## Acceptance criteria

- [ ] `eval.enabled = false` (default): the tool is present in the registry but
      returns a "disabled" error when called; no kernel is started.
- [ ] With `eval.enabled = true` and Python installed: `{"kernel": "python",
      "cell": "1 + 1"}` returns `{"result": "2", "ok": true}`.
- [ ] Python state persists across calls in the same session: define `x = 10` in
      one call, read `x` in the next, get `10`.
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
      `eval.cleanup_delay_ms`.
- [ ] Unit tests cover: magic prefix parsing, kernel registry lifecycle, bridge
      auth token check.

## Open questions / future work

- **JS kernel state.** Bun worker module scope is wiped on restart. Whether to
  serialize the state Map to disk on each cell completion (for crash recovery)
  or accept ephemeral state is unresolved.
- **Output streaming.** Cell output currently returned as a single chunk after
  completion. Long-running cells (training loops, slow HTTP calls) would benefit
  from streaming partial stdout back via the `/api/run` SSE channel, using the
  same `\x01{"type":"eval_output",...}` protocol the tool-status events use.
- **Rich output (matplotlib, Vega).** Python cells that produce figure objects
  currently return only the repr text. Detecting `plt.show()` or a Vega spec and
  returning a base64 PNG or JSON for the web UI to render is a natural follow-on.
- **Kernel quota.** Nothing prevents a runaway cell from consuming unbounded CPU
  or memory. `cgroups`-based resource limits per kernel directory are worth
  adding before the feature is enabled by default.
- **Per-kernel working directory.** Currently kernels inherit the clanker
  process's cwd. Setting cwd to `state/kernels/<session-id>/<type>/` per kernel
  would isolate file writes without any fs_prefix changes.
