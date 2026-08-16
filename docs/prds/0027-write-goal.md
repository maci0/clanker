# PRD — `write-goal` drafting

## Status

Shipped. `write_goal` is the draft-only half of the goal workflow. Its source
of truth is `tools/zig/write_goal.zig`; `clanker write-goal` and TUI
`/write-goal` call it directly. The three related but independent operations
are specified in [0035-goal-lifecycle.md](0035-goal-lifecycle.md).

A follow-on requirement is specified below but not yet implemented: a draft
must propose measurable completion criteria when the caller supplied none, and
must propose a concrete test script for any measurable criterion (Goal 4; the
matching acceptance box is unchecked). Drafting is otherwise unaffected by the
goal-is-a-card change in 0035: the draft is still a review artifact, and
`add_goal` is what turns it into a goal-card.

## Problem

A rough request may need a reviewable completion contract before it is saved
or executed. Drafting must not create a durable record or start work merely
because somebody asked for help wording that contract. And a completion
contract is not a contract if it has no checkable finish line, so drafting
must supply one when the caller did not.

## Goals

1. Turn a rough intent into a structured, readable draft.
2. Ask only material questions, or record assumptions when interaction is not
   possible.
3. Never write `state/goals.json`, create a card, or execute an agent run.
4. When no measurable completion criterion is supplied, draft one; when the
   criterion is measurable, propose a concrete test script (proof) that checks
   it.

## Non-goals

- Persisting a goal. `add_goal` (`tools/zig/add_goal.zig`) owns that explicit
  operation — shipped as a `state/goals.json` append, becoming a goal-card
  create under 0035's Goal 7.
- Executing a goal. `goal` owns starting a goal loop; `run --goal <id>` starts
  that loop from a selected persisted record.
- Making drafting mandatory before either operation.

## Design

`write_goal` inspects existing open goals, asks at most four material questions
through `ask_user`, and returns both a structured record and Markdown. Its
record can include objective, completion criteria, verification, boundaries,
an execution approach, stop rules, assumptions, and unresolved questions.
If the caller supplied no measurable criterion, `write_goal` drafts one rather
than leaving it blank; if the criterion is measurable (time elapsed, a score
reached, an eval passing, a file present), it proposes a concrete test script
as the `proof`. It is a review artifact, not a persistence format: `add_goal`
creates the durable record (a goal-card, under 0035's Goal 7) from the selected
fields, and `state/goals.json` is only an index over those cards.

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
| No measurable criterion is supplied | The draft proposes one, plus a test script when it is measurable |

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
- [ ] A draft with no supplied measurable criterion proposes one, and a
      measurable criterion carries a concrete test script as its `proof`.
      (Goal 4)

## Open questions / future work

The current persisted goal record deliberately flattens parts of the richer
draft. If preserving every draft field becomes necessary, design a versioned
stored record rather than silently widening `add_goal` — under the
goal-is-a-card model that versioning question applies to card fields, not a
separate file.
