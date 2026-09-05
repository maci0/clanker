# ADR 0042 — Session permission modes sit on confirm_writes; the sandbox always-denied tier never lifts

## Status

Accepted — 2026-08-21. Records the decision opened in [RFC 0030 — How session permission modes sit on confirm_writes](../rfcs/0030-permission-modes.md). Not yet implemented. Tracked as [PRD 0053](../prds/0053-session-permission-modes-on-confirm-writes.md).

## Context

Kimi has manual/yolo/auto and approve-for-this-session. Clanker has confirm_writes never|browser|always. RFC 0030 compared a mode enum plus allow-set, aliasing onto confirm_writes, hooks, and status quo.

## Decision

Add a session mode (manual/yolo/auto) and a session allow-set on top of confirm_writes. Yolo skips regular confirms but not plan-exit or secrets. Auto also skips ask_user. Descriptor sandbox and dotenv refusal never lift.

> The RFC recommended: **Recommended option:** Adopt Option A: session mode enum on top of confirm_writes, plus a session allow-set


## Consequences

Attended and unattended sessions get kimi-shaped names. Honest downside: two knobs (confirm_writes and mode) need a precedence table or operators will think /yolo disables the sandbox.
