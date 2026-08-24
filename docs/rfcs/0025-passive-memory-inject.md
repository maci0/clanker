# RFC 0025 — Whether every agent turn injects memory hits without a tool call

## Status

Decided — 2026-08-21. ADR 0037

## Overview

jcode passively injects cosine memory hits every turn. clanker memorySearch fires only on /api/run; REPL and clanker run require the model to call the memory tool. Decide whether every Agent.run turn injects hits on the existing hash embedder.

**Decision to make.** Should every Agent.run turn inject memory hits without a tool call, on the existing hash embedder?

**Why now.** /api/run injects; REPL and clanker run do not. The model forgets to call memory. jcode does it every turn. Inventory: docs/research/jcode-features.md. RFC 0004 out-of-scoped auto-inject of Muninn hits; this is the Knowledge hash-embed path PRD 0007 already ships, applied to every turn.

**Drivers.** Retrieved fences stay untrusted (<retrieved_memory_hits>). Size-capped. Same guest as /api/run (memory WASM), not a native second search. No ONNX (PRD 0007 non-goal). No sidecar LLM verify in v1 (defer). Extraction is a later phase of the same PRD, not this RFC's merge.

**Out of scope.** Muninn graph (RFC 0004). Vendored MiniLM. Ambient garden (ADR 0008).

## Current state

src/cli.zig memorySearch is called from handleRun (/api/run) only. tools/zig/memory.zig search is a catalog tool. REPL/clanker run Agent.run does not inject. Workaround: hope the model calls memory, or use the web UI. Files: share memorySearch with Agent.run (src/agent/loop.zig or a helper both call), keep the fence and cap from PRD 0007.

## Options considered

### Option A — Inject memorySearch on every Agent.run turn, same guest and fence as /api/run

What it is: before the first completion of a turn, run the memory guest search over Knowledge with the user text, prepend <retrieved_memory_hits> (existing untrusted preamble), cap bytes. Opt-in via memory.backend already (off when keyword/none). Extraction (session-end) is a later PRD phase.

Maturity: /api/run path already ships this (PRD 0007). jcode does it every turn with a graph we are not copying.

How it would fit: extract memorySearch from cli.zig into a helper Agent.run and handleRun both call. No ONNX.

Pros: one implementation; REPL/run/web agree; fences already exist.

Cons: hash embed recall is weak; junk hits cost tokens. Fail-open on search error.

Cost to adopt: move a helper, call it from the loop. Cost to leave: stop calling it.

Evidence: src/cli.zig memorySearch; PRD 0007; RFC 0004 out of scope on Muninn inject.

### Option B — Sidecar LLM verifies hits before inject (jcode)

What it is: extra completion per turn to filter hits.

How it would fit: another ck_llm / client.chat on the hot path.

Pros: fewer junk hits.

Cons: latency and cost every turn; PRD 0007 deferred embed quality first.

Cost to adopt: a second model call. Cost to leave: disable it.

Evidence: jcode MEMORY_ARCHITECTURE.md sidecar.

### Option C — status quo

What it is: /api/run injects; REPL does not; tool exists.

Pros: no surprise tokens in the TUI.

Cons: two surfaces disagree; the model forgets the tool.

Cost to adopt: zero; web UI stays the only auto-RAG surface.

Evidence: memorySearch callers.

### Option D — out of the box: note_write / learnings already inject into the system prompt

What it is: state/learnings.md is already in the system prompt. Operators write notes.

How it would fit: tell people to use notes instead of memory search.

Pros: already shipped.

Cons: not retrieval; unbounded prompt; not Knowledge RAG.

Cost to adopt: docs. Cost to leave: n/a.

Evidence: note_write tool; system prompt assembly.

## Implications by horizon

### Short term (this release / 0–3 months)

If A: REPL/run get the same inject /api/run already has. If B: every turn pays a second completion. If status quo: TUI stays tool-only. If D: learnings keep growing the system prompt.

### Medium term (3–12 months)

If A: extraction phase can fill Knowledge from sessions. If B: sidecar cost dominates.

### Long term (12+ months)

If A: swapping the embedder later does not change the inject site. If C: two RAG stories forever.

## Recommendation

**Recommended option:** Option A: inject memorySearch on every Agent.run turn via the existing guest and fence; no ONNX, no sidecar in v1

**Confidence:** 8/10

**Rationale.** Closes the surface split without a new embedder. Sidecar is priced every turn. learnings are not retrieval. RFC 0004 remains about Muninn I/O, not this inject.

## References



- Research: [jcode feature inventory](../research/jcode-features.md).
- PRD 0007, RFC 0004, ADR 0015. jcode MEMORY_ARCHITECTURE.md (2026-08-21).
