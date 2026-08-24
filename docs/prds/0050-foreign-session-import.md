# PRD — Foreign session import

## Status

Draft. Later phases, not implement-now this round. Decision: [ADR 0039](../adrs/0039-foreign-transcripts-import-as-new-clanker-sessions-claude.md). RFC: [0027](../rfcs/0027-foreign-session-resume.md).

## Problem

A crashed Claude Code (or later Codex/OpenCode/pi) session cannot continue in clanker. Own sessions resume; foreign transcripts can only be pasted as a user message, losing tool history.

## Goals

1. clanker session import parses Claude Code JSONL into a new session.  2. Unknown schema is refused, not partially imported.  3. The foreign file is not mutated.  4. Other harnesses are later phases.

## Non-goals

Driving the foreign CLI (RFC 0020). Writing back to their format. Mutating their file. ACP session resume (PRD 0030). Partial import of unknown schema.

## Design

**Parser.** parseClaudeCodeJsonl(bytes) -> []Message or error. Fail-closed. Host-tested against a fixture with user/assistant/tool_use/tool_result.

**Store.** Creates a new session id via the existing session store (ADR 0033). Does not open theirs.

**CLI.** clanker session import <path> [--from claude-code].

**Dependencies.** Hard: ADR 0039, ADR 0033, src/agent/session.zig. Soft: RFC 0020, session_export.

**Implementation.** later, not implement-now this round.

1. Claude Code JSONL parser + tests. Files: tools/zig/session_import_logic.zig (create), build.zig host_tested_helpers.
2. sessions guest op + clanker session import. Files: tools/zig/sessions.zig, src/cli.zig.
3. Codex / OpenCode / pi adapters. Files: tools/zig/session_import_logic.zig.

## Failure modes

| Condition | Behaviour |
|---|---|
| Unknown schema / missing role | Refuse, no session created |
| Empty file | Refuse |
| Path unreadable | Diagnostic, exit 2 |

## Acceptance criteria

1. [ ] A Claude Code JSONL fixture becomes a session with those messages (Goal 1)
2. [ ] Truncated JSONL is refused (Goal 2)
3. [ ] The fixture file bytes are unchanged after import (Goal 3)
4. [ ] Codex is not claimed in phase 1 (Goal 4)

## Open questions / future work

Exact Claude Code schema version to pin. Other harnesses in phase 3.
