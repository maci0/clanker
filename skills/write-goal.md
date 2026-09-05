---
title: Writing a goal
description: When asked to draft, write, or save a structured goal (`clanker write-goal`, `/write-goal`, `goal_write`/`goal_add`). Not `clanker goal` or `/goal`, which start the loop.
enabled: true
---

# Writing a goal

Do not make a draft a prerequisite for `goal_add`; persistence is a separate explicit choice.

Call `goal_write` with the intent (and any workspace facts you already
inspected). It asks only the material forks via `ask_user`, or records
assumptions when nobody is reachable. It never writes `state/goals.json` or
creates a card.

Present the returned markdown. If the caller explicitly wants it saved, call
the `goal_add` tool with the selected fields. `goal_add` appends the durable
record to `state/goals.json`; the board card appears when the web UI mirrors
goals onto the board (`mirrorGoalsToBoard`), so a headless save shows no card
until the Goals view syncs. Map the draft onto the `goal_add` tool's field
names (`completion_criterion`, `proof`, `stop_rule`, not the `goal_write`
record's `completion_criteria` / `verification` / `stop_rules`). A well-formed
goal record carries these fields (`objective, completion_criterion, proof,
boundaries, stop_rule`):

- `objective`: what will be true afterwards, not what you will do. "Runs survive
  a restart", not "add persistence to runs".
- `completion_criterion`: a test someone else could apply and reach the same
  verdict. If two readers could disagree about whether it is met, rewrite it.
  If the caller supplied none, draft a measurable one (time elapsed, a score
  reached, an eval passing, a file present). If it is measurable, also write a
  concrete test script as the `proof`.
- `proof`: the artifact that shows it, named exactly. A command and its expected
  output, a file that must exist, an eval that must pass. For a measurable
  criterion this is a test script the evaluator can run, not a prose summary.
- `boundaries`: what stays untouched, plus any assumption made for want of an
  answer. This is what refuses scope creep later.
- `stop_rule`: when to abandon the attempt rather than keep spending. An
  iteration cap, a failing gate, a missing dependency.
- `worktree`: when the run lives in its own git worktree, name it (branch/path)
  so the goal is tied to that worktree's context.

Only `objective` is required; a missing `completion_criterion` is drafted as a
measurable one (and a test script when measurable) rather than left blank. A
goal that stops at objective + criterion is worth keeping when the rest is
genuinely unknown. Prefer a short honest goal to a padded one.

`goal_write` already inspects `state/goals.json` for an open goal covering
the intent. `goal_add` only appends; it cannot update an existing entry and
does not create the board card. If it reports a duplicate, return that id.
