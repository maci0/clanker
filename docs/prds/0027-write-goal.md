# PRD — `write-goal` (goal drafting)

## Status

Draft. No `write_goal` tool exists; nothing in `src/` or `tools/manifests/`
names one. What does exist is `skills/write-goal.md` — 32 lines of prompt
guidance folded into the system prompt by
`src/agent/system_prompt.zig:338-376` — which tells the model to interview
with `ask_user` and then call the `goal` tool. This PRD promotes that
guidance into a capability with a fixed output contract.

**`write-goal` and `goal` are different things and this PRD does not
conflate them.** `goal` (`tools/zig/goal.zig`,
`tools/manifests/goal.tool.json`) persists and steers execution; that is its
job and this PRD does not change it. `write-goal` produces the draft that
`goal` later persists. The pipeline `write-goal → draft → goal → clanker run
--goal <id>` is not aspirational: everything downstream of the draft already
ships (`src/cli.zig:3018-3024`, `:2680`).

Two things a reader should not walk away misinformed about:

1. **`proof` and `stop_rule` are write-only today.** `goal.zig` writes them
   and `StoredGoal` (`src/cli.zig:8960-8971`) stores them, but no reader
   exists — see Known issues. Drafting them better has no effect on a run
   until that is fixed.
2. **The five-field list is not settled.** The repo already uses "all five
   fields" to mean something different from what this PRD's §Design means
   by it. That collision is recorded in Known issues and is deliberately
   left undecided pending a product call. Per `README.md`'s bar, this Draft
   is therefore **not yet "planned properly"** — that one decision is the
   blocker.

## Problem

Users hand agents requests like "clean up the auth code", "make this service
production ready", "fix the flaky tests". A colleague can act on those. A
long-running agent cannot, because none of them say what state must exist at
the end, how that state is proven, what is out of scope, how to iterate, or
when to stop instead of grinding.

What follows is not one failure but five, pulling in opposite directions —
which is why "write a better prompt" does not fix it: the agent stops to ask
mid-run having burned setup context first; scope creeps, because nothing said
where the work ends; it declares victory early, because nothing said what
done means; it polishes forever, because nothing said when to stop; and it
reports success it never verified, because nothing named the proof.
Premature completion and endless polishing are the same missing field seen
from two sides — fix one without the other and the failure just moves.

Clanker feels this concretely. `clanker goal "<intent>"` (`src/cli.zig:4134`)
and `/goal <intent>` (`src/tui/repl.zig:640`) both synthesize the same
literal prompt — *"Define all five fields (objective, completion_criterion,
proof, boundaries, stop_rule) and call the goal tool to persist it"*
(`src/cli.zig:4142`, `src/tui/repl.zig:2201`) — and then hand the whole
job to a normal turn. The quality bar for a goal lives in one duplicated
string plus a skill file, with no structured intermediate anyone can inspect,
reuse, or refuse. Whatever the model produces is appended to
`state/goals.json` and immediately becomes what steers runs, because the
newest active goal auto-steers (`src/cli.zig:3018-3024`).

There is no point in the flow where a draft exists and has not yet been
committed to. That is the gap.

## Goals

1. A rough natural-language intent becomes a goal that names an end state,
   its proof, its boundaries, an execution loop, and a stop rule.
2. The draft is produced without asking anything the workspace already
   answers — test command, language, CI config, conventions.
3. Questions that *are* asked are few (1–4), concrete, offer options, and
   are material: they change scope or the completion condition, or they are
   not asked.
4. The draft is emitted as a structured record another component can consume
   without parsing prose, alongside a readable Markdown rendering.
5. Drafting neither persists nor executes. Handing the draft to `goal` is a
   separate, user-visible step.
6. No budget appears in a goal unless the user supplied one, and no budget
   is ever written into objective text.
7. An existing goal can be refined without discarding requirements the user
   already stated explicitly.
8. When interaction is unavailable, the draft is emitted best-effort with
   its unresolved assumptions named, never silently invented.

## Non-goals

- **Persisting or executing.** `goal` owns persistence
  (`tools/zig/goal.zig`) and `--goal <id>` / auto-steer owns execution
  (`src/cli.zig:3018-3024`). `write-goal` stops at the draft. The split is
  the point: it creates the review moment that today's flow has nowhere to
  put, and it means a bad draft costs nothing but the draft.
- **Changing the `goal` tool's append-only contract.** That it cannot update
  an existing entry is a real constraint this PRD works within (see
  Refinement in Design), not one it fixes.
- **Implementation planning.** A goal names the destination. Prescribing the
  route is a different job — clanker already has one in `improve.plan_phase`
  — and it actively harms an autonomous run: an agent handed a step list
  cannot discover that the assumed fix was wrong.
- **Inventing requirements.** Not budgets, not constraints, not acceptance
  bars the user never mentioned. A goal that looks more detailed than the
  user's actual intent is a worse goal, not a better one.
- **Turning ordinary prompts into goals.** Most requests are not goals. The
  harness may surface the option once; it must not silently substitute.
- **Coupling drafting to permission mode.** Drafting a goal is not consent
  to run it, however permissive the ambient policy is.

## Design

**The shape: a compiler, not an executor.** Rough intent → context
inspection → material clarification → completion contract → a draft another
component can act on. Every stage narrows ambiguity; none acts on the
workspace.

**The required fields.** Each answers one question and has a specific,
predictable failure mode when omitted — which is why the list is closed
rather than a style guide:

| Field | Answers | Failure if omitted |
|---|---|---|
| Objective | What must be true when this is finished? | Agent optimizes effort, never terminates |
| Completion criteria | Which concrete conditions must hold? | "Done" becomes the model's opinion, unreviewable |
| Proof / verification | What observable evidence shows they hold? | Success is claimed, not demonstrated |
| Boundaries | What may and may not be touched? | Scope creep, collateral edits |
| Execution loop | How should it iterate toward the criteria? | Agent stops at the first failed attempt |
| Stop rule | When must it stop and report? | Agent forces past a real blocker, or grinds |

**Which five is not decided.** The table above is six rows because the repo
disagrees with itself about the grouping. `skills/write-goal.md`,
`goal.tool.json`, and both command prompts say the five are *objective,
completion_criterion, proof, boundaries, stop_rule* — splitting end-state
into two and having no execution-loop field at all. This PRD's source
framing groups them as *end state, proof, boundaries, loop, stop rule*.
Both are called "all five fields" in the same tree. **This is the one
blocker to decide before implementation**; the options and their blast
radius are in Known issues. Nothing else in this PRD depends on which way it
goes, only on it being one way.

The objective states an outcome, not a command sequence. Criteria should be
observable and binary where possible — "the identified flaky tests no longer
fail under repeated execution", not "code quality is improved". **A
completion criterion with no plausible proof mechanism is a defect in the
goal, not a soft spot**; that pairing is the whole artifact.

Proof can be tests, builds, lint, type checks, benchmarks, runtime
observation, API responses, generated artifacts, or diff inspection. What
matters is that someone who did not watch the run can inspect it afterwards.

The stop rule is about **honesty, not spending** — it lets an agent end by
reporting a blocker instead of faking a pass. It is deliberately not a
budget; clanker already has a budget surface in the per-goal
`max_iterations` (`src/cli.zig:8957`, clamped 1..1000 on write). Conflating
them produces goals that stop for the wrong reason.

**Inspect before asking.** Resolve what the workspace answers — repo
structure, existing tests, CI config, build files, conventions, docs —
before putting anything to the user. Asking "what test command should be
used?" with `build.zig` sitting right there is the fastest way to train
users to skip the feature.

**Clarification uses `ask_user`.** The mechanism already exists
(`tools/zig/ask_user.zig`, `sequential: true`, two-or-more concrete options,
answer returned verbatim). Reserve it for answers that would materially
change the goal. Four kinds of ambiguity, three of which are not questions:

| Kind | Example | Action |
|---|---|---|
| Harmless implementation | "Map or set internally?" | Do not ask; the executor decides |
| Discoverable | "What command runs the tests?" | Inspect the workspace |
| Material product | "Must the API stay backward compatible?" | Ask |
| Unresolvable | "Make it fast enough." | Ask for the observable target, unless a benchmark or requirement already fixes it |

**Output is dual.** A readable Markdown render (`## Goal`, then
`### Completion criteria`, `### Verification`, `### Boundaries`,
`### Execution approach`, `### Stop and report if`) over a structured record
(`objective`, `completion_criteria[]`, `verification[]`, `boundaries[]`,
`execution_loop`, `stop_rules[]`, `assumptions[]`, `unresolved_questions[]`).
The Markdown is a rendering of the record, not the source of truth.

The record's arrays do not match `StoredGoal`'s flat strings
(`src/cli.zig:8960-8971`). Reconciling them is a lossy join in one direction
only: the draft's arrays flatten to strings when handed to `goal`, and
nothing flattens back. That is acceptable because `goal` is the terminal
consumer, but it means **the draft, not the stored goal, is the reviewable
artifact** — a point worth keeping if a later PRD widens `StoredGoal`.

**Budgets are opt-in, and a turn cap is not a stop rule.** Limits appear only
when the user supplies them. A well-specified goal already terminates — the
proof passes or the stop rule fires — so an invented cap adds nothing but
the risk of severing work mid-change. A budget belongs to the *run*, not the
objective text: writing "stop after 20 turns" into a goal body makes it
non-portable, unreviewable against its own criteria, and silently different
whenever the executor's turn granularity changes. Clanker's existing
`max_iterations` field is where such a value goes.

**Refinement preserves.** Given an existing draft, flag unverifiable
completion, missing stop rule, over-prescription, unclear scope,
contradictory criteria, requirements disguised as assumptions, missing
proof, and ambiguous terminology — then repair those and leave explicit
requirements intact. Rewriting an already-specific goal is a regression.

Refining a goal that has *already been persisted* is constrained by
`goal`'s append-only contract: `write-goal` can emit a corrected draft, but
committing it means either a duplicate entry or a `POST /api/goals` update
(`src/cli.zig:8949`, the only path that can modify an entry). The skill's
existing duplicate-avoidance rule — read `state/goals.json` first, return the
existing id rather than appending a near-copy — carries over unchanged.

**Do not over-specify.** "Open `src/auth.ts`, add a mutex on line 82, change
`retryCount` to 3, then add two tests" is worse than "eliminate the
authentication race condition while preserving current external behavior;
add regression coverage reproducing the race; verify the normal suite
passes" — because the first forecloses the discovery that the assumed
diagnosis was wrong, which is exactly what a long-running agent is there to
find.

**Drafting is decoupled from permission mode.** Explicit invocation opens an
interactive drafting session regardless of the policy that would later govern
execution. This is not hypothetical: Kimi Code hit exactly this edge, filed
as [MoonshotAI/kimi-code#1329](https://github.com/MoonshotAI/kimi-code/issues/1329)
(open as of 2026-08-14). Their `write-goal` drafts via `AskUserQuestion`
while `auto` mode denies `AskUserQuestion` by policy, so returning to draft
the next goal after one finishes fails with *"AskUserQuestion is disabled
while auto permission mode is active"*; the reporter's workaround is to leave
`auto` manually first. Clanker avoids inheriting this by not coupling the two.

When interaction genuinely cannot be obtained — headless runs, the improve
loop, sub-agents — emit a best-effort draft and name the unresolved
assumptions explicitly. `skills/write-goal.md` already specifies this
(record the assumption in `boundaries`) and that behavior carries over.
Silently inventing the answer is the one thing that is never acceptable,
because it is indistinguishable from a confident correct draft.

**Relationship to Kimi Code.** The framing is borrowed and the divergence is
deliberate. Kimi's built-in skill
(`packages/agent-core-v2/src/app/skillCatalog/builtin/write-goal.md`)
describes itself as turning rough intent into "a completion contract with a
clear finish line, proof, boundaries, and stop rule", and their `GOAL.md`
§"辅助写 goal" lists end state / proof / boundaries / loop / stop rule. Two
rules are taken directly and are **not** divergences: budgets are opt-in, and
a turn cap never goes in objective text.

The divergence is the ending. Kimi's skill starts the goal itself — *"only
once the user has approved it do you start the goal by calling `CreateGoal`…
Do not just print the text for the user to paste."* Clanker's does not,
because clanker already has that half: `goal` persists and `--goal` steers.
Folding starting into `write-goal` would duplicate a shipped tool and destroy
the review moment the split exists to create.

**Dependencies.**

- Hard: `ask_user` (`tools/zig/ask_user.zig`) for clarification; the
  skill-injection path (`src/agent/system_prompt.zig:338-376`, 24 KB cap at
  `:29`) for any prompt-side component; the five-field decision above.
- Hard, downstream: `goal` (`tools/zig/goal.zig`,
  `tools/manifests/goal.tool.json`) as the only persistence consumer of a
  draft, and its append-only limit.
- Soft: `modules.goal` (`src/config.zig:465`) gates the goal surface;
  `write-goal` should sit behind the same flag rather than a second one.
- Related, not blocking: the proof/stop_rule read gap in Known issues. It
  can be fixed independently and this PRD is worth less until it is.

**Implementation.**

1. **Decide the field list** (blocker; see Known issues). Everything below
   assumes it is settled.
2. Fix the write-only fields first, as its own change:
   `GoalContext` (`src/cli.zig:2604`) gains `proof` and `stop_rule`;
   `goalFromObject` (`:2663`) reads them; `formatGoalSection` (`:2619`)
   emits them into the `## Active goal` preamble. Without this, phases 3+
   improve a draft nothing reads.
3. Tool: `tools/zig/write_goal.zig` + `tools/manifests/write_goal.tool.json`
   (no `build.zig` edit — `build.zig:153-182` auto-discovers; no registry
   edit — `src/tools/registry.zig:189` scans the manifest dir). Input
   `{intent, context?, existing_goal?}`; output the structured record under
   the `{"ok":true,…}` envelope (`tools/zig/lib.zig:187`). No `fs_prefixes`
   — drafting writes nothing.
4. Rewrite `skills/write-goal.md` to drive the tool and stop at the draft,
   replacing the current "interview then call `goal`" flow with "interview,
   draft, present, and only then hand to `goal` on approval".
5. Deduplicate the two command prompts (`src/cli.zig:4142`,
   `src/tui/repl.zig:2201`) into one shared constant so the field list
   cannot drift between surfaces again, then point both at the drafting step.
6. Host-side type for the draft next to its consumer, matching house
   convention (`StoredGoal` at `src/cli.zig:8960`); flatten arrays to
   `StoredGoal`'s strings at the hand-off, not before.
7. Tests: a discoverable fact raises no question; a material fork does;
   question count ≤ 4; drafting leaves the tree clean (no
   `state/goals.json` write); headless mode emits assumptions rather than
   inventing; refinement preserves an explicit requirement; no budget
   without user input; round-trip of the structured record.

## Known issues

- **`proof` and `stop_rule` are write-only.** `tools/zig/goal.zig:31,33`
  writes them and `StoredGoal` (`src/cli.zig:8964-8966`) stores them, but
  no reader exists: `GoalContext` (`src/cli.zig:2604-2616`) carries only
  `id`, `objective`, `completion_criterion`, `boundaries`, `max_iterations`,
  and `section`, and `formatGoalSection` (`:2619-2630`) emits only
  `objective`, `completion_criterion`, and `boundaries` into the run
  preamble. Promised: `skills/write-goal.md` tells the model to define proof
  and stop rule, and both command prompts demand "all five fields". Actual:
  two of the five never reach the executing agent. Fix belongs in
  `src/cli.zig` — `GoalContext`, `goalFromObject`, `formatGoalSection`.
- **Two incompatible "five fields" lists.** Recorded verbatim so the choice
  is made on the facts:

  | | Shipped | This PRD's source framing |
  |---|---|---|
  | 1 | `objective` | end state |
  | 2 | `completion_criterion` | proof |
  | 3 | `proof` | boundaries |
  | 4 | `boundaries` | loop |
  | 5 | `stop_rule` | stop rule |

  Shipped splits end-state into objective + criterion and has no
  execution-loop field anywhere. Adopting shipped and adding `execution_loop`
  as a sixth touches `goal.tool.json`, `tools/zig/goal.zig`, `StoredGoal`,
  `GoalContext`, `formatGoalSection`, the two prompt strings,
  `skills/write-goal.md`, and `ui/app/core/goals.js`. Adopting the
  PRD's grouping touches all of the same plus every existing entry in
  `state/goals.json`. Neither option touches `src/improve/retire.zig`, which
  reads only `id` and `status` under `ignore_unknown_fields`
  (`src/improve/retire.zig:60-75`, `:164`) and so tolerates schema growth by
  design. Undecided; see Design.
- **The goal-designing prompt is duplicated verbatim.** `src/cli.zig:4142`
  and `src/tui/repl.zig:2201` hold the same string, including the field
  list. Changing the fields in one and not the other is a silent surface
  split. Fix: one shared constant (Implementation phase 5).
- **PRD 0027 is absent from the inventory.** `docs/prds/README.md`'s table
  stops at 0026 and the build-order list does not mention it.

## Failure modes

| Condition | Behavior |
|---|---|
| Intent is already fully specified | Emit the draft with no questions; do not manufacture clarification to look thorough |
| Intent too vague to ground ("make it better") | Ask for the observable target; do not emit a goal whose criteria are unfalsifiable |
| A completion criterion has no available proof mechanism | Flag it weak in the draft and propose the check that would make it provable, rather than emitting it silently |
| Workspace unreadable / not a repo | Draft from conversation context only; list the workspace facts left unresolved |
| `ask_user` unavailable (headless, improve loop, sub-agent) | Best-effort draft, assumptions recorded in `boundaries` as `skills/write-goal.md` already specifies; never invent silently |
| User supplies no budget | No budget. Not a default, not a suggestion appended to objective text |
| User supplies a budget | Goes to `max_iterations` on the persisted goal (`src/cli.zig:8957`), never into objective text |
| Intent restates an already-open goal | Return that goal's id and explain the overlap; do not draft a near-duplicate for `goal` to append |
| Refining an already-specific goal | Preserve stated requirements; report "no material weaknesses" rather than rewriting to show effort |
| Refining a goal already in `state/goals.json` | Emit the corrected draft, but note that committing needs `POST /api/goals`; `goal` cannot update |
| `modules.goal` is off | Same refusal as `cmdGoal` (`src/cli.zig:4138`); do not offer a drafting flow whose output has nowhere to go |
| Draft fails its own self-check | Incomplete — do not present it as finished |

## Acceptance criteria

- [ ] The field-list blocker is decided and recorded in Design; the repo has
      exactly one "five fields" list.
- [ ] `proof` and `stop_rule` reach the executing agent — verified by a test
      asserting both appear in the `## Active goal` preamble for a goal that
      defines them.
- [ ] `write-goal` is invocable explicitly and accepts an incomplete
      natural-language intent.
- [ ] A vague request ("fix the flaky tests") yields a draft containing every
      required field.
- [ ] Completion criteria are evaluable by a reader who did not run the
      drafting session — verified by handing a generated draft to a fresh
      agent and confirming it states the finish line without follow-ups.
- [ ] Every completion criterion is paired with a named proof mechanism or
      flagged weak.
- [ ] A workspace-discoverable fact (the project's test command) is
      discovered, not asked — verified by asserting no `ask_user` call is
      raised for it when the file naming it is present.
- [ ] A material scope question *is* asked when nothing in the workspace
      settles it.
- [ ] A drafting interaction asks no more than four questions.
- [ ] Invoking `write-goal` writes nothing — verified by asserting
      `state/goals.json` is unchanged and the tree is clean afterwards.
- [ ] Handing a draft to `goal` is a separate step the user can decline.
- [ ] No budget field appears unless the user supplied one; no turn cap
      appears in objective text under any circumstances, including when the
      user supplies one.
- [ ] Refinement preserves already-explicit requirements and repairs only
      the named weaknesses.
- [ ] With `ask_user` unavailable, the draft names its unresolved
      assumptions rather than resolving them silently.
- [ ] An intent restating an open goal returns that goal's id instead of a
      near-duplicate draft.
- [ ] The structured record round-trips: `goal` can be called from it
      without re-parsing the Markdown.
- [ ] The goal-designing prompt exists in exactly one place.

## Open questions / future work

- **Should `StoredGoal` widen to arrays?** The draft carries
  `completion_criteria[]`, `verification[]`, `boundaries[]`, `stop_rules[]`;
  `StoredGoal` holds flat strings, so the hand-off flattens and cannot
  reverse. Widening it would make the persisted goal as reviewable as the
  draft, at the cost of migrating existing `state/goals.json` entries and
  every reader. Not required for this PRD, which treats the draft as the
  reviewable artifact.
- **A `validate-goal` capability** — scoring an existing goal for
  verifiability, ambiguity, scope completeness, evidence quality, autonomy
  suitability, and stop-rule quality. Overlaps the refinement path but is a
  scoring surface rather than a rewriting one; whether they share an
  implementation is open.
- **Should the harness proactively suggest `write-goal`** for obviously
  underspecified long-running work? Design permits it and forbids silent
  substitution, but the trigger heuristic is unspecified, and a bad one is
  worse than none — a false positive on an ordinary request is the most
  irritating possible failure for this feature.
- **Metrics need a surface that does not exist.** The signals worth having —
  share of drafts accepted unedited, mean clarification count, share of runs
  terminating with inspectable evidence, mid-run clarification rate, edits by
  field, post-start scope corrections — presume instrumentation nothing
  currently emits. The target is not "more detailed prompts"; it is fewer
  ambiguous execution loops, because the agent knows what success means
  before it starts. Which of these is worth wiring is open.
