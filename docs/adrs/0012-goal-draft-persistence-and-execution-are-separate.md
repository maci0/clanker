# ADR 0012 — Goal draft, persistence, and execution are separate capabilities

## Status

Accepted.

## Context

Goal-related commands had been described as a required pipeline even though
the operator needs three different actions: improve wording without side
effects, save a durable goal without starting work, and start a goal loop from
a raw condition. Coupling them makes a headless loop ask unnecessary
clarifying questions, hides when a board save starts work, and lets one surface
silently substitute for another.

## Decision

Keep `write_goal`, `add_goal`, and `goal` separate. `write_goal` drafts only;
`add_goal` persists only; `goal` starts a goal loop only. Each has a direct CLI
and TUI entry point. `run --goal <id>` starts that loop from an existing record,
and the web board creates through `add_goal`.

## Consequences

Operators choose the lifecycle step explicitly, and every surface can state
whether it will write or run before it does so. This adds one named command and
one TUI delimiter, and callers that want a draft followed by persistence must
carry the selected fields across themselves. That small handoff is intentional:
it preserves the review boundary rather than making a draft an implicit grant
to persist or execute.
