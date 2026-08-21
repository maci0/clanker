# PRD — Passive memory inject on every turn

## Status

Draft. Later phases, not implement-now this round. Decision: [ADR 0037](../adrs/0037-every-agent-run-turn-injects-memory-hits-through-the.md). RFC: [0025](../rfcs/0025-passive-memory-inject.md).

## Problem

memorySearch injects Knowledge hits only on /api/run. REPL and clanker run require the model to call the memory tool, so those surfaces have no RAG unless the model remembers.

What breaks or is impossible without this, stated from the situation that
forced the decision, not from the solution. Include real constraints
(no server to mediate, must ride an existing transport, sandbox must be
able to enforce it) that shaped the design, not just the desired outcome.

## Goals

1. Agent.run injects memory hits through the same guest, fence, and byte cap as /api/run.  2. Search errors fail open and do not block the turn.  3. No ONNX and no sidecar verifier in v1.  4. Session-end extraction is a named later phase, not silent.

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

ONNX embedder (PRD 0007 non-goal). Sidecar LLM verify in v1. Muninn auto-inject (RFC 0004 / ADR 0015). Ambient garden (ADR 0008).

## Design

**Same guest.** Agent.run calls the memory WASM search handleRun already uses (memorySearch helper extracted from cli.zig). Same fence, preamble, byte cap, fail-open.

**When.** Once per user turn, before the first completion, using the user text. Not after every tool result (token burn).

**Dependencies.** Hard: ADR 0037, PRD 0007, src/cli.zig memorySearch, src/agent/loop.zig. Soft: RFC 0004.

**Implementation.** later, not implement-now this round.

1. Extract memorySearch to a helper both handleRun and Agent.run call. Files: src/agent/memory_inject.zig (create), src/cli.zig (edit), src/agent/loop.zig (edit).
2. Session-end extraction into Knowledge. Files: tools/zig/memory.zig, src/agent/loop.zig.
3. Optional sidecar verify. Files: src/agent/memory_inject.zig.

## Failure modes

| Condition | Behaviour |
|---|---|
| memory.backend off / keyword none | No inject |
| Search error | Fail-open, turn continues |
| Hits exceed cap | Truncate, keep fence |

## Acceptance criteria

1. [ ] Agent.run prepends retrieved_memory_hits when backend is vector/hybrid and Knowledge has a matching chunk (Goal 1)
2. [ ] A search error does not fail the turn (Goal 2)
3. [ ] No ONNX model file is added (Goal 3)
4. [ ] Extraction is documented as phase 2, not shipped as silent (Goal 4)

## Open questions / future work

Whether to inject after tool results as well (probably not). Extraction quality.
