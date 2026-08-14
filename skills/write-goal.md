# Writing a goal

Use this skill only when the caller asks to draft, define, or refine a
structured goal. Do not intercept `clanker goal "<intent>"` or `/goal
<intent>`: those execute the supplied goal directly. Do not make a draft a
prerequisite for `add_goal`; persistence is a separate explicit choice.

Call `write_goal` with the intent (and any workspace facts you already
inspected). It asks only the material forks via `ask_user`, or records
assumptions when nobody is reachable. It never writes `state/goals.json`.

Present the returned markdown. If the caller explicitly wants it saved, call
the `add_goal` tool with the selected fields. Map the draft onto the add-goal
tool's field names (`completion_criterion`, `proof`, `stop_rule`, not the
`write_goal` record's `completion_criteria` / `verification` / `stop_rules`).
A well-formed goal carries these five fields
(`objective, completion_criterion, proof, boundaries, stop_rule`):

- `objective`: what will be true afterwards, not what you will do. "Runs survive
  a restart", not "add persistence to runs".
- `completion_criterion`: a test someone else could apply and reach the same
  verdict. If two readers could disagree about whether it is met, rewrite it.
- `proof`: the artifact that shows it, named exactly. A command and its expected
  output, a file that must exist, an eval that must pass.
- `boundaries`: what stays untouched, plus any assumption made for want of an
  answer. This is what refuses scope creep later.
- `stop_rule`: when to abandon the attempt rather than keep spending. An
  iteration cap, a failing gate, a missing dependency.
- `worktree`: when the run lives in its own git worktree, name it (branch/path)
  so the goal is tied to that worktree's context.

Only the first two are required, and a goal that stops there is worth keeping
when the rest is genuinely unknown. Prefer a short honest goal to a padded one.

Read `state/goals.json` first. The `add_goal` tool only appends; it cannot update an
existing entry. If the intent restates an open goal, do not call `add_goal` and
create a duplicate. Return that goal's id and explain that it already covers
the intent.
