# Writing a goal

When asked to write, define or set a goal (including `clanker goal "<intent>"`),
interview first, then persist. A one-line intent never contains all five fields,
and inventing them produces a goal that reads well and cannot be checked.

Use `ask_user` for the forks where guessing wastes the work: what counts as
done, which surface is in scope, whether existing behaviour may change. Concrete
options, one question per fork. Skip what the intent already answers. When
nobody answers (headless runs, the improve loop, sub-agents), write the goal
anyway and record the assumption in `boundaries`.

Then call the `goal` tool once:

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

Only the first two are required, and a goal that stops there is worth keeping
when the rest is genuinely unknown. Prefer a short honest goal to a padded one.

Read `state/goals.json` first. The `goal` tool only appends; it cannot update an
existing entry. If the intent restates an open goal, do not call `goal` and
create a duplicate. Return that goal's id and explain that it already covers
the intent.
