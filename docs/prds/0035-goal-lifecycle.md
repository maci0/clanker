# PRD — Goal lifecycle capabilities

## Status

Shipped. `write_goal` drafting, `add_goal` persistence, and the shared
continuing goal loop are implemented. A loop starts its first agent turn
immediately, evaluates each completed turn, and continues until achieved,
blocked, cancelled, or budget-limited. Sources of truth are `tools/zig/write_goal.zig`,
`tools/zig/add_goal.zig`, `src/agent/`, `src/cli.zig`, `src/tui/repl.zig`, and
`ui/app/features/goals.js`. The architecture decision is
[ADR 0012](../adrs/0012-goal-draft-persistence-and-execution-are-separate.md).

A follow-on requirement is specified below but not yet implemented: a goal
started without measurable acceptance criteria gets them drafted by the model,
and any measurable criterion gets a generated test script the evaluator runs
(Goals 5–6; the matching acceptance boxes are unchecked).

## Problem

Previously the words “goal” and “write-goal” described incompatible flows:
some surfaces instructed the agent to draft and persist before execution,
while a user needs to be able to draft, save, or run independently. That made
`clanker run "/goal …"` leak a slash command into an ordinary model prompt and
made the web board bypass the persistence tool.

A second problem is the finish line itself. A rough intent ("make it fast") is
not a checkable completion condition, so a loop that keeps working until
"achieved" needs a measurable criterion to test against — either supplied by
the operator or drafted from the intent.

## Goals

1. Each operation has one effect and is directly available from CLI and TUI.
2. Starting a goal loop accepts a raw completion condition with no draft or
   stored record.
3. Persistence creates a durable record without starting work, including from
   the goal board.
4. A stored record remains startable later by id from the CLI or web UI.
5. A goal started without measurable acceptance criteria gets them drafted by
   the model before the loop begins; when the operator supplies measurable
   criteria, those are used verbatim.
6. Any measurable criterion gets a concrete verification artifact — a test
   script or eval — that the evaluator runs to judge completion.

## Non-goals

- Requiring the sequence `write-goal → add-goal → goal`.
- Treating a Kanban card as a goal record. The board mirrors a goal by id but
  remains its own card store.
- Replacing the operator’s final Done/Archive workflow decision: evaluator
  achievement moves a saved goal to Review.
- Letting the model declare "achieved" without running the measurable check.
  The test script is the arbiter, not the model's summary.

## Design

### Command contract

| Capability | CLI | TUI | Effect | Does not do |
|---|---|---|---|---|
| Draft | `clanker write-goal "<intent>"` | `/write-goal <intent>` | Returns a structured review draft | Persist or execute |
| Persist | `clanker add-goal "<objective>" ["<completion criterion>"]` | `/add-goal <objective> [:: <completion criterion>]` | Appends a durable record and prints its id; a missing criterion is drafted as measurable criteria plus a test script | Draft, execute, or imply approval to run |
| Goal loop | `clanker goal "<condition>"` | `/goal <condition>` | Starts a goal loop immediately; a non-measurable condition is drafted into measurable criteria plus a test script first | Require a draft or saved id |
| Saved goal loop | `clanker run --goal <id>` | — | Starts the loop from exactly that stored record | Create a new goal |

`clanker run "/goal <condition>"` is a goal-loop alias for `clanker goal
"<condition>"`; it must never reach the model as a literal slash command.

### Goal-loop semantics

Starting a goal immediately starts its first agent turn. At the end of every
turn the harness evaluates the completion condition against the work and its
recorded verification. If the condition is not met, it starts the next turn
with the current progress and the evaluator’s reason. It does not return to the
operator between ordinary iterations.

The loop ends only when the condition is achieved, the worker reports a real
blocker, a configured budget/deadline is reached, the provider/runtime fails,
or the operator cancels it. A successful one-turn answer is not completion by
itself. The final state and reason are visible to the TUI and web UI; a
headless CLI invocation stays alive until one of those terminal states.

This is the semantic model used by [Claude Code’s `/goal`](https://code.claude.com/docs/en/goal)
and [Kimi Code goals](https://moonshotai.github.io/kimi-code/en/guides/goals.html):
the input is a finish condition, not merely the text of one ordinary turn.
Clanker may use different storage and evaluation internals, but it must retain
the same “keep working until a terminal condition” behavior.

A completion condition may be a rough intent or an explicit measurable
criterion. A measurable criterion is anything a script can check — time
elapsed, a score reached, an eval passing, a file present, a command exiting
zero. When the criterion is measurable, it is used verbatim and the loop's
first work is to write a test script (or eval) that checks it. When it is not
measurable, the model drafts measurable criteria from the intent and then
writes the same test script. The evaluator runs that script at the end of each
turn and reports pass or fail, so "achieved" is a measured result rather than
the model's opinion.

### Persistence implementation

`add_goal` is the sandboxed writer for `state/goals.json`. It accepts
`objective` with an optional `completion_criterion` (plus optional proof,
boundaries, stop rule, worktree, and a `max_iterations` integer from 1 through
1000). When `completion_criterion` is omitted, the drafting path generates a
measurable criterion and a test-script `proof` before the record is appended,
so a persisted goal is always checkable. Its only successful side effect is
appending the record. CLI, TUI, and `POST /api/goals`
for a new board goal call that tool. The HTTP handler holds the existing goal
file lock while it invokes the guest so a simultaneous status update cannot
overwrite the append.

The board’s regular “Add goal” form saves only. Its explicit “Work as goal”
action saves a missing goal and then starts it; that action combines two user
choices visibly, rather than making persistence itself execute.

### Goal-loop implementation

`src/agent/goal_loop.zig` constructs loop state rather than submitting a
normal one-turn task. The loop owns the condition, turn count, latest evaluator reason,
and terminal status. A saved-goal start uses its stored objective, completion
criterion, verification, boundaries, and stop rule as that loop’s condition
and context. A raw start uses the supplied condition without creating a stored
goal. `agent.max_goal_turns` bounds completed agent turns separately from
`agent.max_iterations`, which bounds tool/model rounds inside each turn.

## Failure modes

| Condition | Behaviour |
|---|---|
| `add-goal` omits the objective | CLI/TUI show usage; the guest refuses malformed JSON without writing |
| `add-goal` omits the completion criterion | The drafting path generates measurable criteria and a test script, then appends the record |
| A raw `goal` intent has no measurable finish line | The model drafts measurable criteria and a test script before the first turn |
| A measurable criterion is supplied (time elapsed, score, eval, file) | It is used verbatim; a test script is generated to check it |
| The generated test script fails | The loop continues; the evaluator reports the failure and the reason |
| Goal module is disabled | Each direct surface reports the module-disabled error; no fallback loop/run occurs |
| Unknown `run --goal` id | The loop is refused rather than attaching a different active goal |
| Board save fails | The form preserves the typed fields and reports the tool/API error; it does not start a run |
| A raw `goal` condition has no prior draft | The loop starts normally; no hidden draft or persisted record is created |

## Acceptance criteria

- [x] `write-goal` and `/write-goal` only draft.
- [x] `add-goal` and `/add-goal` only persist and provide a later run id.
- [x] `goal`, `/goal`, and `run "/goal …"` start a raw goal loop, not a
  one-turn run.
- [x] Each loop continues through successive turns until it is achieved,
  blocked, cancelled, or hits a configured limit.
- [x] `run --goal <id>` starts a saved goal loop without creating another one.
- [x] The web goal board's "Work on this" starts a stored goal's loop by id
  (Goal 4).
- [x] The web goal board creates through `add_goal` and does not auto-run.
- [x] CLI help, TUI help, manifests, skills, PRDs, ADR, reports, and the
  roadmap each state the same one-effect-per-operation contract (Goal 1).
- [ ] A goal started without a measurable criterion gets one drafted before the
      first turn, plus a test script the evaluator runs (Goal 5).
- [ ] A supplied measurable criterion (time elapsed, score reached, eval, file)
      is used verbatim and gets a generated test script (Goals 5–6).
- [ ] The evaluator judges completion by running the test script, not by a
      model's summary (Goal 6).

## Open questions / future work

The TUI’s two-field persistence syntax uses ` :: ` as an explicit delimiter.
If the TUI gains a structured form, it may replace that syntax while retaining
the same `add_goal` call and no-run invariant.

Whether the generated test script is a shell script under the workspace, an
`evals/*.task.json` entry, or both is not yet pinned; the requirement is only
that the evaluator can run it and reach the same verdict a human would.
