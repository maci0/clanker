# PRD — Goal lifecycle capabilities

## Status

Shipped. The goal lifecycle has three independent capabilities: draft with
`write_goal`, persist with `add_goal`, and execute with `goal`. Their
implementations are `tools/zig/write_goal.zig`, `tools/zig/add_goal.zig`,
`src/cli.zig`, `src/tui/repl.zig`, and `ui/app/features/goals.js`. The
architecture decision is [ADR 0012](../adrs/0012-goal-draft-persistence-and-execution-are-separate.md).

## Problem

Previously the words “goal” and “write-goal” described incompatible flows:
some surfaces instructed the agent to draft and persist before execution,
while a user needs to be able to draft, save, or run independently. That made
`clanker run "/goal …"` leak a slash command into an ordinary model prompt and
made the web board bypass the persistence tool.

## Goals

1. Each operation has one effect and is directly available from CLI and TUI.
2. Direct execution accepts a raw prompt with no draft or stored record.
3. Persistence creates a durable record without starting work, including from
   the goal board.
4. A stored record remains runnable later by id from the CLI or web UI.

## Non-goals

- Requiring the sequence `write-goal → add-goal → goal`.
- Treating a Kanban card as a goal record. The board mirrors a goal by id but
  remains its own card store.
- Changing existing status updates, archival, or the run completion lifecycle.

## Design

### Command contract

| Capability | CLI | TUI | Effect | Does not do |
|---|---|---|---|---|
| Draft | `clanker write-goal "<intent>"` | `/write-goal <intent>` | Returns a structured review draft | Persist or execute |
| Persist | `clanker add-goal "<objective>" "<completion criterion>"` | `/add-goal <objective> :: <completion criterion>` | Appends a durable record and prints its id | Draft, execute, or imply approval to run |
| Execute | `clanker goal "<prompt>"` | `/goal <prompt>` | Starts a normal agent run with the supplied goal | Require a draft or saved id |
| Execute saved | `clanker run --goal <id>` | Goal board “Work on this” | Starts a run against exactly that stored record | Create a new goal |

`clanker run "/goal <prompt>"` is an execution alias for `clanker goal
"<prompt>"`; it must never reach the model as a literal slash command.

### Persistence implementation

`add_goal` is the sandboxed writer for `state/goals.json`. It accepts
`objective` and `completion_criterion`, with optional proof, boundaries, stop
rule, worktree, and a `max_iterations` integer from 1 through 1000. Its only
successful side effect is appending the record. CLI, TUI, and `POST /api/goals`
for a new board goal call that tool. The HTTP handler holds the existing goal
file lock while it invokes the guest so a simultaneous status update cannot
overwrite the append.

The board’s regular “Add goal” form saves only. Its explicit “Work as goal”
action saves a missing goal and then starts it; that action combines two user
choices visibly, rather than making persistence itself execute.

### Execution implementation

`goal`/`/goal` construct a direct-work task prompt and submit the normal agent
run. The prompt explicitly says that a `write_goal` draft and an `add_goal`
record are optional separate capabilities. `run --goal <id>` instead loads the
existing record and adds it as the active-goal preamble.

## Failure modes

| Condition | Behaviour |
|---|---|
| `add-goal` omits either required field | CLI/TUI show usage; the guest refuses malformed JSON without writing |
| Goal module is disabled | Each direct surface reports the module-disabled error; no fallback persistence/run occurs |
| Unknown `run --goal` id | The run is refused rather than attaching a different active goal |
| Board save fails | The form preserves the typed fields and reports the tool/API error; it does not start a run |
| A direct `goal` prompt has no prior draft | The run starts normally; no hidden draft or persisted record is created |

## Acceptance criteria

- [x] `write-goal` and `/write-goal` only draft.
- [x] `add-goal` and `/add-goal` only persist and provide a later run id.
- [x] `goal`, `/goal`, and `run "/goal …"` execute directly from raw text.
- [x] `run --goal <id>` executes a saved goal without creating another one.
- [x] The web goal board creates through `add_goal` and does not auto-run.
- [x] CLI help, TUI help, manifests, skills, PRDs, and the roadmap state the
  same separation.

## Open questions / future work

The TUI’s two-field persistence syntax uses ` :: ` as an explicit delimiter.
If the TUI gains a structured form, it may replace that syntax while retaining
the same `add_goal` call and no-run invariant.
