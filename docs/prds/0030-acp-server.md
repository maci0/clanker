# PRD — ACP server (`clanker acp`)

## Status

In progress. `clanker acp` (`cmdAcp` in `src/cli.zig`) and
`src/acp/server.zig` exist: stdio JSON-RPC framing, `initialize`
(protocol v1, baseline-only prompt capabilities), `authenticate` (empty
success), and `session/cancel` as a silent notification. Gated by
`modules.acp` (default false). `session/new`,
`session/prompt`, `session/update`, and `session/request_permission` are
not wired; unknown methods return `-32601`. Modeled on
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)'s
`packages/acp/acp/`, a minimal, automation-only reference implementation of
the [Agent Client Protocol](https://agentclientprotocol.com).

## Problem

Clanker already speaks MCP as a *server* — `clanker mcp` opens a stdio
JSON-RPC connection exposing the tool registry to an MCP client — but has no
equivalent for being driven *as an agent* by an external program. The Agent
Client Protocol is the open protocol Zed (and other ACP-aware editors) use
to embed a coding agent inside an editor: the editor spawns the agent as a
subprocess, opens a session, sends prompts, and renders the agent's streamed
answer inline. Clanker's own docs already name this exact absence in
writing: `docs/reviews/webui.md`'s Kimi Code harness parity table lists
"ACP/IDE integration (`kimi acp` equivalent)" as an explicit gap, not a
vague aspiration — the target is literally "the same shape as `kimi acp`."

DSH's `acp/acp` package is a useful reference precisely because it is
narrow: an "automation-only" server that does not try to cover editor
navigation, transcript replay, or human-question UI — those stay with
whatever surface already owns them (clanker's case: the REPL's ask/confirm
modal, the web UI's ask bridge). ACP itself is a transport, not a second
product surface.

## Goals

1. `clanker acp` opens a JSON-RPC 2.0 connection on stdin/stdout. Stdout
   carries protocol frames only; every log line goes to stderr, the same
   discipline `clanker run` already keeps for a clean stdout pipe.
2. Implement the baseline ACP method table:
   - `initialize` — negotiate the supported protocol version, advertise
     baseline-only prompt capability (no image/audio/embedded-resource
     support in v1).
   - `authenticate` — a no-op; the server advertises no authentication
     methods, matching `clanker serve`'s own default loopback-trust posture
     (auth is a concern for whatever spawns the process, not for the wire).
   - `session/new` — create a fresh `Agent` bound to an absolute `cwd`.
   - `session/prompt` — run one turn to quiescence; report `end_turn` on
     normal completion or `cancelled` on an ACP-level cancel.
   - `session/cancel` — cancel one session's in-flight prompt; unknown ids
     are no-ops.
   - `session/update` — stream `agent_message_chunk` notifications built
     from committed assistant text as a turn progresses.
   - `session/request_permission` — bridge to the existing confirm channel
     (see Design), offering one-shot allow/reject.
3. One connection may own several sessions (several concurrent `Agent`
   instances), each independently prompt-able and cancellable.
4. Client disconnect cancels every session the connection owns, sets the
   existing `stop_flag` each session's `chatStream` already checks, and
   joins before the process exits — no orphaned agent threads.

## Non-goals

- **Session resume, fork, or list over ACP.** Fresh sessions only in v1 —
  the same "Known Limitation" DSH's own implementation states outright
  rather than hiding.
- **Image, audio, or embedded-resource content blocks.** Baseline text
  prompts only; a resource link is not fetched, only carried as a bracketed
  textual reference the model may open with its own tools (same simplifying
  choice DSH makes).
- **Live, uncommitted token streaming beyond `agent_message_chunk`.** No
  raw-delta or in-progress tool-activity event on the wire. DSH's own
  reasoning is the reasoning to keep: "committed answers only" trades
  token-by-token latency for a clean automation result, and uncommitted
  provider chunks or retry attempts must never leak partial text to an
  automation client. Reasoning and tool activity stay visible through
  clanker's other surfaces (the run's own graph, `clanker graph`), not ACP.
- **A second web server.** `clanker acp` is a stdio process, spawned
  per-connection by the ACP client (the editor), exactly the way `clanker
  mcp` already works. It does not open a socket.

## Design

**Shape mirrors `clanker mcp`.** `cmdMcp` (`src/cli.zig`, ~4787) already
establishes the pattern this PRD copies: gate on a `modules.*` flag, load
config, hand off to a `serve()` function owning a stdio JSON-RPC loop.
`cmdAcp` follows the same shape, delegating to `src/acp/server.zig`, so the
two subcommands read as siblings rather than two different architectures for
"expose clanker over stdio JSON-RPC."

**Permission bridge reuses the existing confirm channel.**
`session/request_permission` needs a one-shot allow/reject answer for a
bridge-owned approval request — exactly what `Agent.confirm_fn`
(`host.ConfirmFn`) already provides for the web UI's `/api/ask` and the
REPL's modal. `clanker acp` installs a `confirm_fn` that turns a pending
tool call into an ACP `session/request_permission` request and blocks on the
client's answer, rather than inventing a second approval mechanism.

**Turn-to-quiescence, not a re-plumbed streaming path.**
`session/prompt` runs the target `Agent`'s turn on its own thread (the same
"run the model on a background thread, block the caller until settled"
shape the vaxis REPL already uses for `Agent.run`) and emits `session/update`
notifications from the existing `on_tool_call`/`on_tool_result` observer
hooks as they fire, rather than re-plumbing `client.chatStream`'s
token-level streaming into the ACP wire. This is the same choice DSH made
and for the same reason (see Non-goals): a clean committed-message result is
worth more to an automation client than raw deltas.

**`stopReason`, honestly incomplete.** ACP requires every prompt response to
carry a `stopReason`. Clanker's loop has no turn-scoped type today
distinguishing "hit the model's natural end" from "hit a token-budget
ceiling" — both collapse to whatever `Agent.run` returns. v1 reports
`end_turn` for both and `cancelled` only for an explicit ACP-level cancel or
disposal, which is honest about what clanker can currently tell apart. This
is named as a real gap in Open questions rather than quietly reported as a
finer distinction than the loop actually makes.

**Dependencies.** None hard. Reuses `host.ConfirmFn`/`host.AskFn` (shipped),
`Agent.run` and its `stop_flag` (shipped), and `cmdMcp`/`mcp.serve` as a
structural template (shipped). No other Draft PRD blocks starting.

**Implementation.**

1. `src/acp/server.zig`: JSON-RPC 2.0 framing and method dispatch skeleton,
   unit-tested against literal request/response fixtures (no real `Agent`
   involved yet).
2. `session/new` / `session/prompt` / `session/cancel` wired to `Agent.run`
   on a per-session background thread.
3. `session/update` notification emission from `on_tool_call`.
4. `session/request_permission` wired to a new `confirm_fn` implementation.
5. `cmdAcp` + `modules.acp` config gate + docs.
6. Verification against a scripted JSON-RPC fixture exercising the full
   method table end to end; a real ACP client (Zed, if reachable in a test
   environment) is a stretch goal, not a blocker.

## Failure modes

| Condition | Behaviour |
|---|---|
| `modules.acp = false` (default) | `clanker acp` exits with `ModuleDisabled`, same as `clanker mcp` today |
| Malformed JSON-RPC frame | Protocol-level parse error response; connection stays open |
| `session/prompt` on an unknown session id | JSON-RPC error; no crash |
| A second concurrent `session/prompt` on the same session | Rejected — one in-flight prompt per session |
| Client disconnects mid-turn | Session cancelled, `stop_flag` set, thread joined before process exit |
| `session/new` names a non-existent or relative `cwd` | Rejected at session creation, absolute `cwd` required |

## Acceptance criteria

- [x] `modules.acp = false` refuses to start (`cmdAcp` returns
      `ModuleDisabled`). Default is false.
- [x] `initialize` negotiates a version and advertises baseline-only prompt
      capability.
- [ ] `session/new` creates an `Agent` bound to the given `cwd`; a relative
      or missing `cwd` is rejected.
- [ ] `session/prompt` runs a turn to quiescence and reports `end_turn` on
      normal completion.
- [ ] `session/cancel` on an in-flight prompt reports `cancelled` for that
      prompt and stops the turn. Unknown ids are already a silent no-op.
- [ ] `session/update` emits one `agent_message_chunk` notification per
      committed assistant text chunk.
- [ ] `session/request_permission` round-trips through the same
      `confirm_fn` path a web UI `/api/ask` answer already uses.
- [ ] Client disconnect cancels every session the connection owns and the
      process exits with no orphaned threads.
- [ ] A second `session/prompt` on a session already mid-prompt is rejected.

## Open questions / future work

- **A real turn-scoped stop-reason type.** Would let ACP (and eventually the
  web UI) report token-limit-stopped vs. naturally-ended vs. cancelled
  honestly instead of collapsing to `end_turn`. Worth doing once there is a
  second consumer that would use the distinction, not invented for ACP
  alone.
- **Session resume/fork over ACP.** Natural future work once this ships,
  riding the same `session.branchSession`/archive machinery the web UI's
  Branch button already uses — not attempted in v1 because DSH's own
  ACP server does not support it either, and getting fresh-session ACP
  right first is the smaller, checkable step.
