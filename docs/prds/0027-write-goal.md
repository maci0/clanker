# PRD — `write-goal` drafting

## Status

Shipped. `write_goal` is the draft-only half of the goal workflow. Its source
of truth is `tools/zig/write_goal.zig`; `clanker write-goal` and TUI
`/write-goal` call it directly. The three related but independent operations
are specified in [0035-goal-lifecycle.md](0035-goal-lifecycle.md).

## Problem

A rough request may need a reviewable completion contract before it is saved
or executed. Drafting must not create a durable record or start work merely
because somebody asked for help wording that contract.

## Goals

1. Turn a rough intent into a structured, readable draft.
2. Ask only material questions, or record assumptions when interaction is not
   possible.
3. Never write `state/goals.json`, create a card, or execute an agent run.

## Non-goals

- Persisting a goal. `add_goal` (`tools/zig/add_goal.zig`) owns that explicit operation.
- Executing a goal. `goal` owns starting a goal loop; `run --goal <id>` starts
  that loop from a selected persisted record.
- Making drafting mandatory before either operation.

## Design

`write_goal` inspects existing open goals, asks at most four material questions
through `ask_user`, and returns both a structured record and Markdown. Its
record can include objective, completion criteria, verification, boundaries,
an execution approach, stop rules, assumptions, and unresolved questions.
It is a review artifact, not a persistence format: `state/goals.json` stores
the smaller executable record selected by `add_goal`.

The same tool is exposed on both direct surfaces:

| Surface | Invocation | Result |
|---|---|---|
| CLI | `clanker write-goal "<intent>"` | Prints a draft only |
| TUI | `/write-goal <intent>` | Prints a draft only |
| Agent tool | `write_goal` | Returns the structured record and Markdown |

## Failure modes

| Condition | Behaviour |
|---|---|
| Intent is already covered by an open goal | Returns the existing goal id instead of drafting a duplicate |
| A material choice needs a person but no one is reachable | Returns a best-effort draft with explicit assumptions/unresolved questions |
| `ask_user` refuses or fails | Returns the draft with the unresolved fork recorded; it does not persist or run |

## Acceptance criteria

- [x] A rough intent yields a structured, readable draft — the `record`
      (objective, completion criteria, verification, boundaries, stop rules,
      assumptions, unresolved questions) plus a Markdown rendering. (Goal 1)
- [x] Only the material open forks are asked, at most four questions; when no
      answer is reachable, assumptions and unresolved questions are recorded
      instead of silently invented. (Goal 2)
- [x] Drafting never writes `state/goals.json`, creates a card, or executes an
      agent run. (Goal 3)
- [x] CLI (`clanker write-goal`), TUI (`/write-goal`), and the agent tool all
      invoke the same `write_goal` tool and receive the same draft. (Goal 1)
- [x] Persisting (`add_goal`) and executing (`goal` / `run --goal`) work
      without a prior draft — drafting is optional, never a prerequisite.
      (Goal 3)

## Open questions / future work

The current persisted goal record deliberately flattens parts of the richer
draft. If preserving every draft field becomes necessary, design a versioned
stored record rather than silently widening `add_goal`.
