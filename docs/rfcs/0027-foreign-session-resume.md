# RFC 0027 — Whether clanker imports foreign harness session transcripts

## Status

Decided — 2026-08-21. ADR 0039

## Overview

jcode resumes Claude Code, Codex, OpenCode, and pi sessions. clanker resumes only its own store (ADR 0033). RFC 0020 drives those CLIs as children, it does not parse their logs. Decide whether to import foreign transcripts.

**Decision to make.** Should clanker import foreign harness transcripts (Claude Code, Codex, OpenCode, pi) into a clanker session, and which format ships first?

**Why now.** Operators lose work when those CLIs die. RFC 0020 drives the CLI as a child; it does not parse the log. Own sessions already resume (ADR 0033). Inventory: docs/research/jcode-features.md.

**Drivers.** Session ids stay validSessionId. Import is a new session, not a mutate of theirs. Untrusted text: their tool output is untrusted the same as ours. WASM-by-default: parser is a guest helper, host-tested. One format in phase 1.

**Out of scope.** Driving those CLIs (RFC 0020 / ADR 0032). ACP session resume (PRD 0030 non-goal). Writing back into their format.

## Current state

clanker sessions are per-id SQLite (ADR 0033) or the still-supported JSON path during migration. --continue/--session resume ours. No importer. Workaround: paste the transcript as a user message. Files: tools/zig/session_import.zig (or sessions guest op), clanker session import CLI.

## Options considered

### Option A — Guest parser, Claude Code JSONL first, writes a new clanker session

What it is: clanker session import <path> [--from claude-code] parses their JSONL into user/assistant/tool messages and creates a new session id. Other formats are later phases. Fail closed on unknown schema.

Maturity: jcode resumes four harnesses. Claude Code JSONL is the most common ask.

How it would fit: host-tested parseClaudeCodeJsonl in tools/zig/session_import_logic.zig; sessions guest op; CLI verb.

Pros: durable; one implementation; tests on fixtures.

Cons: formats drift; we maintain adapters.

Cost to adopt: parser + CLI. Cost to leave: delete the op.

Evidence: jcode README Resume; ADR 0033; RFC 0020.

### Option B — Drive the foreign CLI instead (RFC 0020)

What it is: do not import; keep using their binary.

How it would fit: already decided as a driver, not an importer.

Pros: no schema.

Cons: they have to be alive; the ask is resume after they broke.

Cost to adopt: already in flight elsewhere. Cost to leave: n/a.

Evidence: RFC 0020.

### Option C — status quo

What it is: paste or start over.

Pros: no adapter rot.

Cons: lost tool history and images.

Cost to adopt: zero.

Evidence: no importer in tree.

### Option D — out of the box: session_export HTML is already a portable transcript

What it is: export ours as HTML; ask them to export similarly.

How it would fit: session_export exists; they do not write our HTML.

Pros: we already have an export.

Cons: does not read theirs.

Cost to adopt: docs. Cost to leave: n/a.

Evidence: session_export guest.

## Implications by horizon

### Short term (this release / 0–3 months)

If A: Claude Code JSONL import works on fixtures. If B: you still need their CLI healthy. If status quo: paste. If D: export does not import.

### Medium term (3–12 months)

If A: Codex/OpenCode/pi adapters as later phases. If C: we keep losing those sessions.

### Long term (12+ months)

If A: adapters are a maintenance tax; pin schema versions. If C: never portable in.

## Recommendation

**Recommended option:** Option A: guest parser writing a new clanker session, Claude Code JSONL first

**Confidence:** 7/10

**Rationale.** RFC 0020 is a different question (drive the binary). HTML export does not read theirs. Formats drift, so phase 1 is one adapter with fail-closed parse tests.

## References



- Research: [jcode feature inventory](../research/jcode-features.md).
- ADR 0033, RFC 0020, PRD 0005. jcode RESUME_BEHAVIOR.md and README.
