# PRD — MCP client bridge

## Status

Draft. No source files yet. Proposed: `src/mcp_client/` (stdio and
streamable-HTTP transports, `tools/list`/`tools/call` JSON-RPC), a new
dispatch-kind split in `src/toolhost/registry.zig`'s `Tool` struct, and
`[mcp_servers.<name>]` config stanzas. Gated by `modules.mcp_client = false`
(default off — an explicit opt-in). Modeled on
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)'s
`packages/mcp/mcp-client/`.

## Problem

Clanker only speaks MCP as a *server*: `clanker mcp` exposes its own tool
registry over stdio JSON-RPC to an external MCP client. It cannot *consume*
an external MCP server's tools — the `github` MCP server, a filesystem MCP
server someone already runs, a company-internal one — without hand-writing
a WASM proxy tool per server, which defeats the point of a shared protocol.
`docs/reviews/webui.md`'s Kimi Code harness parity table names this exact
absence: "MCP client configuration (clanker already serves MCP;
`/mcp-config`-style client management is new)" is listed as an explicit gap,
not something this PRD is inventing a need for.

DSH's `mcp-client` package is a proven, minimally-scoped reference for the
wire contract: two transports (stdio, streamable-HTTP), server-qualified
tool naming (`mcp__<server>__<rawName>`) so two servers can both publish a
tool called `search` without colliding, and a reconnect/backoff policy for a
server that drops.

## Goals

1. `[mcp_servers.<name>]` config stanzas, shaped like `[providers.<name>]`:
   `transport = "stdio" | "http"`; `command`/`args`/`env`/`cwd` for stdio,
   `url`/`headers` for http; `tool_call_timeout_ms` (default 60000).
2. At startup, gated by `modules.mcp_client` (default `false`), connect to
   every configured server, call `tools/list`, and register each discovered
   tool into the `Registry` under `mcp__<server>__<rawName>`, normalized to
   clanker's existing tool-name constraints.
3. Dispatching an `mcp__*` tool forwards `{name: rawName, arguments}` over
   the server's existing connection instead of instantiating a WASM module —
   the first registry entry kind not backed by a `.wasm` file (see Design;
   this is the core architectural change this PRD makes, named plainly, not
   folded quietly into "implementation details").
4. Reconnect with exponential backoff on a lost connection (bounded
   attempts, resets after a sustained good connection), the same shape DSH
   ships.
5. `clanker mcp-client list` (or folded into `clanker plugins list` if that
   reads better once built) shows every connected server and its discovered
   tools, so an operator can see what a session actually has access to
   without reading `config.toml`.

## Non-goals

- **MCP Resources or Prompts.** Tools only, matching DSH's own scoping.
- **Per-session server selection.** v1 wires every configured server's
  tools into the process-wide registry, the same way every WASM tool is
  visible to every session today. Scoping which sessions see which MCP
  servers is real future work — see PRD 0033 (Agent presets), which is the
  natural place for a "this preset only sees these servers" rule once both
  exist.
- **Sandboxing an MCP server's execution the way WASM tools are sandboxed.**
  Named plainly below, not glossed over.
- **A web UI panel for adding/removing servers at runtime.** Config-file
  only in v1, matching how `[providers.*]` is configured today.

**The trust boundary this crosses, stated plainly.** Every other tool in
clanker is a fuel-metered, filesystem/network/exec-scoped WASM guest — ADR
0007's entire argument for not fetching or installing plugins is "the
manifest is already the security boundary and it is already enforced." An
MCP server is an arbitrary external process (stdio) or HTTP endpoint the
operator names in config, running with none of that sandboxing: the same
trust level as adding a line to a manifest's `exec_allow` for an arbitrary
binary, except the binary now gets its own tool schemas the model can call
by name without an operator reviewing each one. This is not a relaxation of
the WASM sandbox for existing tools — it is a new, separate, explicitly
opt-in trust boundary, the same one Claude Code's and Codex's own MCP client
configuration already asks a user to accept. Framed here as a deliberate
trade-off named in the PRD, not a gap discovered later.

## Design

**A new registry dispatch kind — the biggest single implementation item.**
`Registry.Tool` (`src/toolhost/registry.zig`) assumes every entry has a
`.wasm` path, resolved and instantiated per call. An MCP-backed entry has no
`.wasm` file at all. The cheapest fit is a dispatch tag on `Tool` —
`dispatch: union(enum) { wasm, mcp_proxy: *McpConnection }` — following the
precedent `internal`/`turn_hook`/`statusline` already set: `Tool`'s meaning
already varies by flag rather than by generating a second kind of struct.
Every call site that currently assumes "resolve wasm bytes, instantiate,
call" — `Agent.executeCalls`, `warmToolCaches`, the parallel-dispatch worker
path in `loop.zig` — needs a second branch. This is real, non-trivial
plumbing and is called out here as the thing to get right first, before
transports or config parsing, because getting the dispatch split wrong
would need re-touching every call site a second time.

**Server-qualified naming, deterministic.** `mcp__<server>__<rawName>`,
normalized to clanker's existing tool-name length/character constraints;
when normalization or truncation would make two different tools collide, a
short deterministic hash of `(server, rawName)` is appended — reusing DSH's
scheme rather than inventing a second normalization rule, since the
property that matters (`(server, rawName)` always maps to the same name,
connection order never renames a tool) is exactly what DSH already got
right.

**Connection lifecycle.** One connection per configured server, held for
the process's lifetime — mirroring how `[providers.*]` credentials are
resolved once at config load, not re-resolved per call. A stdio server is a
long-lived child process, unlike the one-shot spawn-and-wait shape
`execUnderPolicy`/`ck_exec` already provide; it needs a process handle that
survives many tool calls, which is closer to the session-scoped subprocess
registry PRD 0016 already proposes for DAP than to anything that exists
today. This PRD names that as a soft dependency: if PRD 0016's registry
lands first, a long-lived MCP stdio child should be registered there rather
than this PRD building a second process-lifecycle manager from scratch. If
0016 has not landed, this PRD ships its own minimal version (spawn, hold the
handle, kill on process exit) rather than blocking on it.

**Startup failure is per-server, never global.** One unreachable or
misconfigured MCP server logs a warning naming the server and registers no
tools for it; it does not stop clanker from starting or from registering
every other server's tools, the same "one bad file does not take the other
ninety down" principle the manifest validator already applies to a single
malformed `*.tool.json`.

**Dependencies.** Soft: PRD 0016's session/process-scoped subprocess
registry (share, do not duplicate, if it lands first). Hard: none — the
transport and dispatch-split work can start independently of 0016.

**Implementation.**

1. `src/mcp_client/` — stdio and streamable-HTTP transports, `tools/list` /
   `tools/call` JSON-RPC client, unit-tested against a fake in-process MCP
   server (no real network/process dependency in tests).
2. `Registry.Tool` dispatch-kind split, plus updates at every call site that
   assumes a `.wasm` path (`Agent.executeCalls`, `warmToolCaches`, the
   worker-dispatch path).
3. `[mcp_servers.*]` config parsing + `modules.mcp_client` gate.
4. Reconnect/backoff policy (initial delay, doubling, ceiling, bounded
   attempts, reset after sustained uptime).
5. `clanker mcp-client list` (or the `plugins list` extension) surfacing
   connected servers and their discovered tools.
6. Live verification against one real external MCP server (a reference
   filesystem or GitHub MCP server) end to end: discovery, a real call, a
   forced disconnect and recovery.

## Failure modes

| Condition | Behaviour |
|---|---|
| `modules.mcp_client = false` (default) | No servers connected; registry unchanged from today |
| A configured server unreachable at startup | Warning naming the server; its tools absent; every other server and every WASM tool loads normally |
| A server crashes mid-session | Reconnect with backoff; tools from the last good generation stay registered but calls against them fail until recovery |
| Reconnect attempts exhausted | Server's tools unregistered; reconnection stops until process restart |
| Two servers publish the same raw tool name | Both coexist under their own server-qualified name; no collision |
| A server's `tools/list` changes mid-session | v1: not re-synced live (see Open questions); requires a restart to pick up |
| `tool_call_timeout_ms` exceeded | Call fails with a timeout error; connection is not torn down (a slow tool is not a dead server) |

## Acceptance criteria

- [ ] `[mcp_servers.<name>]` stanzas parse with `transport`, stdio
      `command`/`args`/`env`/`cwd`, http `url`/`headers`, and
      `tool_call_timeout_ms` defaulting to 60000 (Goal 1).
- [ ] `modules.mcp_client = false` by default; zero behavior change with it
      off.
- [ ] A configured stdio server's tools are discovered and callable under
      `mcp__<server>__<name>`.
- [ ] A configured streamable-HTTP server's tools are discovered and
      callable the same way.
- [ ] Two servers publishing a tool with the same raw name coexist without
      collision.
- [ ] A tool call forwards `{name, arguments}` and returns the server's
      result through the normal tool-result path — no `.wasm` instantiation
      occurs for an `mcp__*` entry.
- [ ] Startup (Goal 2) connects to every configured server and registers
      each discovered tool; one unreachable server is skipped without
      blocking the others.
- [ ] A server that crashes mid-session reconnects with backoff and its
      tools become callable again on recovery.
- [ ] `clanker mcp-client list` (or its equivalent) shows every connected
      server and its discovered tool names.

## Open questions / future work

- **Live re-sync on `tools/list_changed`.** DSH supports it; clanker's
  registry is built once at startup and assumed static everywhere else in
  the codebase, so live re-sync may be genuinely harder here than it was
  for DSH's plugin-tree architecture. Worth deciding only after the
  dispatch-kind split (Design) is actually built and its real constraints
  are visible — not decided speculatively here.
- **Lazy-loading MCP-sourced tools the way `agent.tool_catalog` already
  lazy-loads WASM tools.** Left open; may or may not fit the same mechanism.
- **Per-session server scoping.** The natural follow-on once PRD 0033
  (Agent presets) exists — a preset naming which MCP servers a session can
  see, the same way it would name a WASM tool allow/deny list.
